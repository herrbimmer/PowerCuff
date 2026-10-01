import Foundation
import IOKit

/// Real-time power rails from the AppleSMC (readable without root). The IORegistry battery
/// telemetry only refreshes every minute or so, which is too slow to close a control loop on.
public struct SMCReading: Sendable, Equatable {
    /// PSTR: total system power, watts (mean over the window).
    public var systemW: Double
    /// PDTR: DC input power from the adapter, watts (mean over the window).
    public var dcInW: Double
    /// Highest readings in the window.
    public var peakSystemW: Double
    public var peakDcInW: Double

    public init(systemW: Double, dcInW: Double, peakSystemW: Double? = nil, peakDcInW: Double? = nil) {
        self.systemW = systemW; self.dcInW = dcInW
        self.peakSystemW = peakSystemW ?? systemW; self.peakDcInW = peakDcInW ?? dcInW
    }
}

private struct KVers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
private struct KPLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
private struct KInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, attributes: UInt8 = 0 }
private typealias KBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
private struct KData {
    var key: UInt32 = 0
    var vers = KVers()
    var pLimit = KPLimit()
    var info = KInfo()
    var pad: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: KBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// Raw AppleSMC key access. Reads work for any user; writes need root (the helper).
public final class SMCConnection: @unchecked Sendable {
    public struct KeyInfo: Sendable, Equatable {
        public var size: Int
        public var type: String
    }

    private var conn: io_connect_t = 0
    private let lock = NSLock()
    private var infoCache: [UInt32: KeyInfo] = [:]

    public init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(conn) }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func string(_ v: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(v >> $0 & 0xFF) }, as: UTF8.self)
    }

    private func call(_ input: inout KData, _ output: inout KData) -> Bool {
        var size = MemoryLayout<KData>.size
        return IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KData>.size, &output, &size) == KERN_SUCCESS
            && output.result == 0
    }

    private func infoLocked(_ k: UInt32) -> KeyInfo? {
        if let c = infoCache[k] { return c }
        var i = KData(), o = KData()
        i.key = k; i.data8 = 9                                    // kSMCGetKeyInfo
        guard call(&i, &o) else { return nil }
        let info = KeyInfo(size: Int(o.info.dataSize), type: Self.string(o.info.dataType))
        infoCache[k] = info
        return info
    }

    /// nil when the key does not exist on this Mac.
    public func info(_ key: String) -> KeyInfo? {
        lock.lock(); defer { lock.unlock() }
        return infoLocked(Self.fourCC(key))
    }

    public func read(_ key: String) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        let k = Self.fourCC(key)
        guard let inf = infoLocked(k), inf.size <= 32 else { return nil }
        var i = KData(), o = KData()
        i.key = k; i.info.dataSize = UInt32(inf.size); i.data8 = 5          // kSMCReadKey
        guard call(&i, &o) else { return nil }
        return withUnsafeBytes(of: o.bytes) { Array($0.prefix(inf.size)) }
    }

    /// Writes raw bytes (SMC byte order). Needs root; `bytes.count` must match the key's size.
    @discardableResult
    public func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = Self.fourCC(key)
        guard let inf = infoLocked(k), inf.size == bytes.count else { return false }
        var i = KData(), o = KData()
        i.key = k; i.info.dataSize = UInt32(inf.size); i.data8 = 6          // kSMCWriteKey
        withUnsafeMutableBytes(of: &i.bytes) { dst in
            for (n, b) in bytes.enumerated() { dst[n] = b }
        }
        return call(&i, &o)
    }

    /// Reads a key of SMC type `flt ` (little-endian Float32).
    public func float(_ key: String) -> Float? {
        guard info(key)?.type == "flt ", let b = read(key), b.count == 4 else { return nil }
        return b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }
}

public final class SMCReader: @unchecked Sendable {
    public static let shared = SMCReader()
    private let smc = SMCConnection()
    private let lock = NSLock()
    private var samples: [(t: UInt64, r: SMCReading)] = []
    private var sampler: DispatchSourceTimer?
    /// Default averaging window in seconds; smooths the burst pattern of duty-cycled processes.
    public var window = 1.0
    /// Samples are kept this long so callers can ask for windows up to `maxWindow`.
    public static let maxWindow = 12.0

    private init() {}

    /// Mean and peak of the 10 Hz samples over the last `window` seconds (default: `self.window`; starts
    /// sampling on first use). The SMC itself only publishes a new value about once per second.
    public func read(window w: Double? = nil) -> SMCReading? {
        lock.lock(); defer { lock.unlock() }
        guard smc != nil else { return nil }
        if sampler == nil { startSampler() }
        let span = min(max(w ?? window, 0.05), Self.maxWindow)
        let cutoff = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- UInt64(span * 1e9)
        var recent = samples.filter { $0.t >= cutoff }
        if recent.isEmpty, let last = samples.last { recent = [last] }
        if recent.isEmpty, let r = readNow() { return r }
        guard !recent.isEmpty else { return nil }
        let n = Double(recent.count)
        return SMCReading(systemW: recent.reduce(0) { $0 + $1.r.systemW } / n,
                          dcInW: recent.reduce(0) { $0 + $1.r.dcInW } / n,
                          peakSystemW: recent.map(\.r.systemW).max(),
                          peakDcInW: recent.map(\.r.dcInW).max())
    }

    private func startSampler() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.powercuff.smc", qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: 0.1, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard let r = self.readNow() else { return }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            self.samples.append((now, r))
            let cutoff = now &- UInt64(Self.maxWindow * 1e9)
            self.samples.removeAll { $0.t < cutoff }
        }
        t.resume()
        sampler = t
    }

    private func readNow() -> SMCReading? {
        guard let smc, let sys = smc.float("PSTR") else { return nil }
        return SMCReading(systemW: Double(sys), dcInW: Double(smc.float("PDTR") ?? 0))
    }
}
