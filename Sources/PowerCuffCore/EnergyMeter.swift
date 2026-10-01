import Foundation

// IOReport (libIOReport, private but stable; used by powermetrics). No root needed for "Energy Model".
@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(_ group: CFString?, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64,
                                         _ c: UInt64) -> Unmanaged<CFMutableDictionary>?
@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(_ a: UnsafeRawPointer?, _ channels: CFMutableDictionary,
                                        _ subbed: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                                        _ id: UInt64, _ b: UnsafeRawPointer?) -> Unmanaged<AnyObject>?
@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(_ sub: AnyObject, _ channels: CFMutableDictionary,
                                   _ a: UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(_ a: CFDictionary, _ b: CFDictionary, _ c: UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ ch: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetUnitLabel")
private func IOReportChannelGetUnitLabel(_ ch: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportSimpleGetIntegerValue")
private func IOReportSimpleGetIntegerValue(_ ch: CFDictionary, _ idx: Int32) -> Int64

/// Power of the SoC blocks the governor can influence, watts.
public struct SoCPower: Sendable, Equatable {
    public var cpuW = 0.0, gpuW = 0.0, aneW = 0.0, dramW = 0.0
    public var totalW: Double { cpuW + gpuW + aneW + dramW }

    public init(cpuW: Double = 0, gpuW: Double = 0, aneW: Double = 0, dramW: Double = 0) {
        self.cpuW = cpuW; self.gpuW = gpuW; self.aneW = aneW; self.dramW = dramW
    }
}

/// SoC energy counters differenced at up to 5 Hz. The SMC rails publish once a second; these follow a load
/// change within ~200 ms, which is what lets the governor catch a burst before it shows up on the wall.
public final class EnergyMeter: @unchecked Sendable {
    public static let shared = EnergyMeter()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.powercuff.energy", qos: .userInitiated)
    private var sub: AnyObject?
    private var channels: CFMutableDictionary?
    private var prev: (t: UInt64, s: CFDictionary)?
    private var samples: [(t: UInt64, p: SoCPower)] = []
    private var timer: DispatchSourceTimer?
    private var interval = 1.0

    public var available: Bool { sub != nil }

    private init() {
        guard let ch = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let s = IOReportCreateSubscription(nil, ch, &subbed, 0, nil)?.takeRetainedValue(),
              let sch = subbed?.takeRetainedValue() else { return }
        sub = s
        channels = sch
    }

    /// Sampling period: 0.2 s while the governor is enforcing, slower when only monitoring.
    public func setInterval(_ seconds: Double) {
        queue.async { [self] in
            guard available, seconds != interval || timer == nil else { return }
            interval = seconds
            timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: seconds, leeway: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.sample() }
            t.resume()
            timer = t
        }
    }

    /// Mean over the last `window` seconds (at least the latest sample). nil until two samples exist.
    public func read(window: Double) -> SoCPower? {
        lock.lock(); defer { lock.unlock() }
        guard let last = samples.last else { return nil }
        let cutoff = last.t &- UInt64(max(window, 0.01) * 1e9)
        let recent = samples.filter { $0.t > cutoff }
        guard !recent.isEmpty else { return last.p }
        let n = Double(recent.count)
        return SoCPower(cpuW: recent.reduce(0) { $0 + $1.p.cpuW } / n,
                        gpuW: recent.reduce(0) { $0 + $1.p.gpuW } / n,
                        aneW: recent.reduce(0) { $0 + $1.p.aneW } / n,
                        dramW: recent.reduce(0) { $0 + $1.p.dramW } / n)
    }

    private func sample() {
        guard let sub, let channels, let cur = IOReportCreateSamples(sub, channels, nil)?.takeRetainedValue() else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { prev = (now, cur) }
        guard let p = prev, now > p.t,
              let delta = IOReportCreateSamplesDelta(p.s, cur, nil)?.takeRetainedValue() as NSDictionary?,
              let items = delta["IOReportChannels"] as? [NSDictionary] else { return }
        let dt = Double(now - p.t) / 1e9
        var soc = SoCPower()
        for item in items {
            let ch = item as CFDictionary
            guard let name = IOReportChannelGetChannelName(ch)?.takeUnretainedValue() as String? else { continue }
            let unit = IOReportChannelGetUnitLabel(ch)?.takeUnretainedValue() as String? ?? ""
            let scale = unit == "mJ" ? 1e-3 : unit == "uJ" ? 1e-6 : unit == "nJ" ? 1e-9 : 0
            let w = Double(IOReportSimpleGetIntegerValue(ch, 0)) * scale / dt
            // Names differ per chip: "CPU Energy" / "DIE_0_CPU Energy", "ANE" / "ANE0", "DRAM0", "GPU SRAM0".
            if name.hasSuffix("CPU Energy") { soc.cpuW += w }
            else if name == "GPU Energy" || name.hasPrefix("GPU SRAM") { soc.gpuW += w }
            else if name.hasPrefix("ANE") { soc.aneW += w }
            else if name.hasPrefix("DRAM") { soc.dramW += w }
        }
        lock.lock()
        samples.append((now, soc))
        let cutoff = now &- 5_000_000_000
        if let first = samples.first, first.t < cutoff { samples.removeAll { $0.t < cutoff } }
        lock.unlock()
    }
}
