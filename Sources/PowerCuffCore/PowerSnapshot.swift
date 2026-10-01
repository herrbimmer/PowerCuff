import Foundation
import IOKit

/// Wall-side estimate for power measured at the Mac's DC input: USB-C/MagSafe cable loss plus brick
/// conversion loss. USB-C PD bricks run 88–94 % efficient at full load and 80–88 % when lightly loaded;
/// the model errs low on efficiency so the wall figure errs high.
public enum AdapterLoss {
    /// Round-trip cable resistance, ohms.
    public static let cableOhms = 0.1

    public static func efficiency(loadFraction x: Double) -> Double { 0.92 - 0.07 * exp(-max(x, 0) / 0.2) }

    /// - Parameters:
    ///   - fixedEfficiency: user calibration (e.g. from a wall meter); replaces the model when set.
    ///   - appleFactor: wall/DC ratio from Apple's own `AdapterEfficiencyLoss` telemetry; used if higher.
    public static func wallW(dcW: Double, ratedW: Double?, volts: Double?, fixedEfficiency: Double? = nil,
                             appleFactor: Double? = nil) -> Double {
        guard dcW > 0 else { return 0 }
        if let e = fixedEfficiency, e > 0.5 { return dcW / e }
        let v = (volts ?? 0) > 4 ? volts! : 20
        let amps = dcW / v
        let rated = (ratedW ?? 0) > 0 ? ratedW! : max(dcW, 60)
        let model = (dcW + amps * amps * cableOhms) / efficiency(loadFraction: dcW / rated)
        let apple = appleFactor.map { dcW * min(max($0, 1), 1.3) } ?? 0
        return max(model, apple)
    }
}

/// One reading of the Mac's power state, from the AppleSmartBattery IORegistry node and the SMC rails.
public struct PowerSnapshot: Equatable, Sendable {
    public var date: Date
    /// Total system load in watts (SoC + display + peripherals).
    public var systemW: Double
    /// Power entering the Mac from the adapter (DC side). 0 on battery.
    public var dcInW: Double
    /// Estimated draw at the wall outlet (DC input plus cable and brick loss). 0 on battery.
    public var wallW: Double
    /// Signed: positive = charging battery, negative = battery is powering the Mac.
    public var batteryW: Double
    /// Highest reading of `controlledW` within the averaging window.
    public var peakW: Double
    public var adapterRatedW: Double?
    public var adapterName: String?
    public var adapterVolts: Double?
    public var externalConnected: Bool
    public var isCharging: Bool
    public var fullyCharged: Bool
    public var percent: Int
    public var minutesRemaining: Int?
    public var temperatureC: Double?
    public var cycleCount: Int?

    public var onAC: Bool { externalConnected }
    /// The number the cap applies to: wall draw on AC, system load on battery.
    public var controlledW: Double { onAC ? wallW : systemW }
    /// Wall watts per DC watt at the current load (1 on battery).
    public var wallFactor: Double { dcInW > 1 && wallW > 0 ? wallW / dcInW : 1 }
    /// Headroom left on the adapter's DC rating.
    public var adapterSpareW: Double? { adapterRatedW.map { max($0 - dcInW, 0) } }

    public init(date: Date = Date(), systemW: Double = 0, dcInW: Double = 0, wallW: Double = 0, batteryW: Double = 0,
                peakW: Double? = nil, adapterRatedW: Double? = nil, adapterName: String? = nil,
                adapterVolts: Double? = nil, externalConnected: Bool = false, isCharging: Bool = false,
                fullyCharged: Bool = false, percent: Int = 0, minutesRemaining: Int? = nil,
                temperatureC: Double? = nil, cycleCount: Int? = nil) {
        self.date = date; self.systemW = systemW; self.dcInW = dcInW; self.wallW = wallW; self.batteryW = batteryW
        self.peakW = peakW ?? (externalConnected ? wallW : systemW)
        self.adapterRatedW = adapterRatedW; self.adapterName = adapterName; self.adapterVolts = adapterVolts
        self.externalConnected = externalConnected; self.isCharging = isCharging
        self.fullyCharged = fullyCharged; self.percent = percent; self.minutesRemaining = minutesRemaining
        self.temperatureC = temperatureC; self.cycleCount = cycleCount
    }

    /// Parses the property dictionary of `AppleSmartBattery`.
    /// - Parameter efficiency: fixed adapter efficiency (user calibration); nil = model.
    public static func parse(_ p: [String: Any], smc: SMCReading? = nil, efficiency: Double? = nil,
                             date: Date = Date()) -> PowerSnapshot {
        func d(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        // Telemetry and current values are signed 64-bit (a negative SystemLoad reads as 1.8e19 unsigned).
        func s(_ v: Any?) -> Double? { (v as? NSNumber).map { Double($0.int64Value) } }

        let telemetry = p["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapter = p["AdapterDetails"] as? [String: Any] ?? [:]
        let connected = (p["ExternalConnected"] as? Bool) ?? false
        let rated = connected ? d(adapter["Watts"]) : nil
        let volts = connected ? d(adapter["AdapterVoltage"]).map { $0 / 1000 } : nil

        var systemW = abs(s(telemetry["SystemLoad"]) ?? 0) / 1000
        let voltsMV = d(p["Voltage"]) ?? 0
        let mA = s(p["InstantAmperage"]) ?? s(p["Amperage"]) ?? 0
        var batteryW = voltsMV * mA / 1_000_000

        // Apple's own adapter-loss estimate; refreshes about once a minute, so it only calibrates.
        var appleFactor: Double?
        if let pin = s(telemetry["SystemPowerIn"]), pin > 5000, let loss = s(telemetry["AdapterEfficiencyLoss"]), loss > 0 {
            appleFactor = (pin + loss) / pin
        }

        var dcInW = connected ? (s(telemetry["SystemPowerIn"]) ?? 0) / 1000 : 0
        var peakDC = dcInW, peakSys = systemW
        if dcInW <= 0 && connected { dcInW = systemW + max(batteryW, 0) }

        if let smc {
            // Live rails: battery flow = adapter input minus load (negative = battery is helping).
            systemW = smc.systemW
            dcInW = connected ? smc.dcInW : 0
            batteryW = connected ? smc.dcInW - smc.systemW : -smc.systemW
            peakDC = connected ? smc.peakDcInW : 0
            peakSys = smc.peakSystemW
        }

        func wall(_ dc: Double) -> Double {
            AdapterLoss.wallW(dcW: dc, ratedW: rated, volts: volts, fixedEfficiency: efficiency, appleFactor: appleFactor)
        }
        let wallW = connected ? wall(dcInW) : 0

        let rawMin = (p["TimeRemaining"] as? NSNumber)?.intValue
        let minutes = (rawMin != nil && rawMin! > 0 && rawMin! < 0xFFFF) ? rawMin : nil

        return PowerSnapshot(
            date: date, systemW: systemW, dcInW: dcInW, wallW: wallW, batteryW: batteryW,
            peakW: connected ? max(wall(peakDC), wallW) : max(peakSys, systemW),
            adapterRatedW: rated,
            adapterName: connected ? adapter["Name"] as? String : nil,
            adapterVolts: volts,
            externalConnected: connected,
            isCharging: (p["IsCharging"] as? Bool) ?? false,
            fullyCharged: (p["FullyCharged"] as? Bool) ?? false,
            percent: (p["CurrentCapacity"] as? NSNumber)?.intValue ?? 0,
            minutesRemaining: minutes,
            temperatureC: d(p["Temperature"]).map { $0 / 100 },
            cycleCount: (p["CycleCount"] as? NSNumber)?.intValue)
    }
}

public enum BatteryReader {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: (t: UInt64, props: [String: Any])?

    /// The registry node is slow to refresh (about once a minute) but costly to copy, so reuse it for a second.
    private static func props() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let c = cache, now &- c.t < 1_000_000_000 { return c.props }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var out: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &out, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = out?.takeRetainedValue() as? [String: Any] else { return nil }
        cache = (now, dict)
        return dict
    }

    /// nil on Macs without a battery or if the registry entry is unreadable.
    /// - Parameters:
    ///   - window: seconds of SMC samples to average (nil = the reader's default, 1 s).
    ///   - efficiency: fixed adapter efficiency; nil = conservative model.
    public static func read(window: Double? = nil, efficiency: Double? = nil) -> PowerSnapshot? {
        guard let dict = props() else { return nil }
        return PowerSnapshot.parse(dict, smc: SMCReader.shared.read(window: window), efficiency: efficiency)
    }
}
