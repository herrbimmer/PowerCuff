import Foundation
import IOKit

/// One reading of the Mac's power state, from the AppleSmartBattery IORegistry node.
public struct PowerSnapshot: Equatable, Sendable {
    public var date: Date
    /// Total system load in watts (SoC + display + peripherals).
    public var systemW: Double
    /// Estimated draw at the wall outlet (adapter DC output plus conversion loss). 0 on battery.
    public var wallW: Double
    /// Signed: positive = charging battery, negative = battery is powering the Mac.
    public var batteryW: Double
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

    /// Wall power ≈ DC input × this (typical USB-C adapter conversion loss).
    public static let adapterLossFactor = 1.05

    public var onAC: Bool { externalConnected }
    /// The number the cap applies to: wall draw on AC, system load on battery.
    public var controlledW: Double { onAC ? wallW : systemW }

    public init(date: Date = Date(), systemW: Double = 0, wallW: Double = 0, batteryW: Double = 0,
                adapterRatedW: Double? = nil, adapterName: String? = nil, adapterVolts: Double? = nil,
                externalConnected: Bool = false, isCharging: Bool = false, fullyCharged: Bool = false,
                percent: Int = 0, minutesRemaining: Int? = nil, temperatureC: Double? = nil,
                cycleCount: Int? = nil) {
        self.date = date; self.systemW = systemW; self.wallW = wallW; self.batteryW = batteryW
        self.adapterRatedW = adapterRatedW; self.adapterName = adapterName; self.adapterVolts = adapterVolts
        self.externalConnected = externalConnected; self.isCharging = isCharging
        self.fullyCharged = fullyCharged; self.percent = percent; self.minutesRemaining = minutesRemaining
        self.temperatureC = temperatureC; self.cycleCount = cycleCount
    }

    /// Parses the property dictionary of `AppleSmartBattery`.
    public static func parse(_ p: [String: Any], smc: SMCReading? = nil, date: Date = Date()) -> PowerSnapshot {
        func d(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func i64(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }

        let telemetry = p["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapter = p["AdapterDetails"] as? [String: Any] ?? [:]
        let connected = (p["ExternalConnected"] as? Bool) ?? false

        var systemW = (d(telemetry["SystemLoad"]) ?? 0) / 1000
        let voltsMV = d(p["Voltage"]) ?? 0
        let mA = Double(i64(p["InstantAmperage"]) ?? i64(p["Amperage"]) ?? 0)
        var batteryW = voltsMV * mA / 1_000_000

        var wallW = 0.0
        if connected {
            if let pin = d(telemetry["SystemPowerIn"]) {
                wallW = (pin + (d(telemetry["AdapterEfficiencyLoss"]) ?? 0)) / 1000
            } else {
                wallW = systemW + max(batteryW, 0)
            }
        }

        if let smc {
            // Live rails: battery flow = adapter input minus load (negative = battery is helping).
            systemW = smc.systemW
            batteryW = connected ? smc.dcInW - smc.systemW : -smc.systemW
            wallW = connected ? smc.dcInW * adapterLossFactor : 0
        }

        let rawMin = (p["TimeRemaining"] as? NSNumber)?.intValue
        let minutes = (rawMin != nil && rawMin! > 0 && rawMin! < 0xFFFF) ? rawMin : nil

        return PowerSnapshot(
            date: date, systemW: systemW, wallW: wallW, batteryW: batteryW,
            adapterRatedW: connected ? d(adapter["Watts"]) : nil,
            adapterName: connected ? adapter["Name"] as? String : nil,
            adapterVolts: connected ? d(adapter["AdapterVoltage"]).map { $0 / 1000 } : nil,
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
    /// `window`: seconds of SMC samples to average (nil = the reader's default, 1 s).
    public static func read(window: Double? = nil) -> PowerSnapshot? {
        guard let dict = props() else { return nil }
        return PowerSnapshot.parse(dict, smc: SMCReader.shared.read(window: window))
    }
}
