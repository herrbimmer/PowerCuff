import Foundation
import IOKit
import PowerCuffCore

func log(_ s: String) {
    FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(s)\n".utf8))
}

/// The root-only levers. Remembers on disk exactly what it changed, so a crash, kill or reboot is undone at the
/// next start and nothing else (another charge-limit tool, the user's own power mode) is ever overwritten.
final class HardLevers {
    struct Saved: Codable, Equatable {
        var charge = false
        var adapter = false
        /// `pmset` key and the values it had per source before we switched Low Power Mode on.
        var powerKey: String?
        var powerBattery: Int?
        var powerAC: Int?
    }

    private let smc: SMCConnection?
    private let dryRun: Bool
    private let statePath: String
    private(set) var saved = Saved()
    /// Charging: CHTE (current firmware) or CH0B+CH0C (older). Adapter: CHIE, else CH0J, else CH0I.
    private let chargeKeys: [(key: String, on: UInt8)]
    private let adapterKey: (key: String, on: UInt8)?
    private let power: (key: String, battery: Int?, ac: Int?)?

    var caps: HelperProtocol.Caps { .init(charge: !chargeKeys.isEmpty, adapter: adapterKey != nil, lowPower: power != nil) }
    var state: HelperProtocol.Levers {
        .init(chargeInhibit: saved.charge, adapterOff: saved.adapter, lowPower: saved.powerKey != nil)
    }

    init(dryRun: Bool, statePath: String) {
        self.dryRun = dryRun
        self.statePath = statePath
        let smc = SMCConnection()
        self.smc = smc
        let has = { (k: String) in smc?.info(k) != nil }
        chargeKeys = has("CHTE") ? [("CHTE", 1)] : has("CH0B") && has("CH0C") ? [("CH0B", 2), ("CH0C", 2)] : []
        adapterKey = has("CHIE") ? ("CHIE", 8) : has("CH0J") ? ("CH0J", 1) : has("CH0I") ? ("CH0I", 1) : nil
        power = Self.readPowerMode()
        log("caps charge=\(chargeKeys.map(\.key)) adapter=\(adapterKey?.key ?? "-") power=\(power?.key ?? "-") dryRun=\(dryRun)")
    }

    // MARK: persistence

    /// Undoes whatever a previous instance left applied.
    func restoreFromDisk() {
        guard let data = FileManager.default.contents(atPath: statePath),
              let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        log("restoring state left by a previous run: \(s)")
        saved = s
        releaseAll()
    }

    private func persist() {
        if saved == Saved() { try? FileManager.default.removeItem(atPath: statePath); return }
        try? FileManager.default.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    // MARK: apply

    /// Brings the levers to `want` (as far as allowed) and returns what is in effect plus an optional note.
    func apply(_ want: HelperProtocol.Levers) -> (HelperProtocol.Levers, String?) {
        var note: String?
        if want.chargeInhibit != saved.charge, !chargeKeys.isEmpty {
            if writeAll(chargeKeys, on: want.chargeInhibit) { saved.charge = want.chargeInhibit; persist() }
            else { note = "smc" }
        }
        var adapterOff = want.adapterOff
        if adapterOff, let pct = Self.batteryPercent(), pct < HelperProtocol.batteryFloor { adapterOff = false; note = "floor" }
        if adapterOff != saved.adapter, let k = adapterKey {
            // Record first: if we die between the write and the save, the next start still switches it back on.
            if adapterOff { saved.adapter = true; persist() }
            if writeAll([k], on: adapterOff) { saved.adapter = adapterOff; persist() }
            else { saved.adapter = false; persist(); note = "smc" }
        }
        if want.lowPower != (saved.powerKey != nil), power != nil { setLowPower(want.lowPower) }
        return (state, note)
    }

    func releaseAll() {
        if saved.adapter { writeAll(adapterKey.map { [$0] } ?? [], on: false); saved.adapter = false }
        if saved.charge { writeAll(chargeKeys, on: false); saved.charge = false }
        if saved.powerKey != nil { setLowPower(false) }
        persist()
    }

    /// Ends battery-only running once the battery gets low, whatever the app asks.
    func enforceFloor() {
        guard saved.adapter, let pct = Self.batteryPercent(), pct < HelperProtocol.batteryFloor else { return }
        log("battery \(pct)% below floor: adapter back on")
        if writeAll(adapterKey.map { [$0] } ?? [], on: false) { saved.adapter = false; persist() }
    }

    @discardableResult
    private func writeAll(_ keys: [(key: String, on: UInt8)], on: Bool) -> Bool {
        var ok = true
        for k in keys {
            guard let size = smc?.info(k.key)?.size, size > 0 else { ok = false; continue }
            let bytes = [on ? k.on : 0] + [UInt8](repeating: 0, count: size - 1)
            if dryRun { log("dry-run: \(k.key) <- \(bytes)"); continue }
            let wrote = smc?.write(k.key, bytes) ?? false
            let back = smc?.read(k.key)
            log("\(k.key) <- \(bytes) \(wrote && back?.first == bytes[0] ? "ok" : "FAILED (read \(back ?? []))")")
            ok = ok && wrote && back?.first == bytes[0]
        }
        return ok
    }

    private func setLowPower(_ on: Bool) {
        guard let p = power else { return }
        if on {
            let now = Self.readPowerMode()
            saved.powerKey = p.key; saved.powerBattery = now?.battery; saved.powerAC = now?.ac
            persist()
            Self.pmset(["-a", p.key, "1"], dryRun: dryRun)
        } else {
            let key = saved.powerKey ?? p.key
            if let b = saved.powerBattery { Self.pmset(["-b", key, String(b)], dryRun: dryRun) }
            if let c = saved.powerAC { Self.pmset(["-c", key, String(c)], dryRun: dryRun) }
            saved.powerKey = nil; saved.powerBattery = nil; saved.powerAC = nil
            persist()
        }
    }

    // MARK: system reads

    /// `powermode` (0 auto, 1 low, 2 high) on Macs with High Power Mode, `lowpowermode` elsewhere.
    static func readPowerMode() -> (key: String, battery: Int?, ac: Int?)? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "custom"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return PMSet.parsePowerMode(text)
    }

    static func pmset(_ args: [String], dryRun: Bool) {
        log("\(dryRun ? "dry-run: " : "")pmset \(args.joined(separator: " "))")
        guard !dryRun else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    static func batteryPercent() -> Int? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        func int(_ k: String) -> Int? {
            (IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        guard let cur = int("CurrentCapacity") else { return nil }
        let max = int("MaxCapacity") ?? 100
        return max > 100 ? cur * 100 / max : cur
    }
}
