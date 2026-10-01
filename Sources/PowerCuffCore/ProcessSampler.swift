import Foundation
import Darwin
import IOKit

public struct ProcInfo: Sendable {
    public let pid: pid_t
    public let name: String
    public let uid: uid_t
    /// Percent of one core over the last sample interval (150 = 1.5 cores).
    public let cpu: Double
    public let ppid: pid_t
    public let pgid: pid_t
    /// Has a controlling terminal (started from a shell in Terminal, not by an app).
    public let hasTTY: Bool
    /// CPU energy rate from the kernel's per-task energy counter, watts. nil for other users' processes.
    public let energyW: Double?
    /// GPU busy time over the interval, as a fraction of wall time (can exceed 1 with several queues).
    public let gpu: Double

    public init(pid: pid_t, name: String, uid: uid_t, cpu: Double, ppid: pid_t = 1, pgid: pid_t = 0,
                hasTTY: Bool = false, energyW: Double? = nil, gpu: Double = 0) {
        self.pid = pid; self.name = name; self.uid = uid; self.cpu = cpu; self.ppid = ppid; self.pgid = pgid
        self.hasTTY = hasTTY; self.energyW = energyW; self.gpu = gpu
    }
}

/// Per-process CPU, energy and GPU usage from libproc / IORegistry deltas. Not thread-safe; use from one queue.
public final class ProcessSampler {
    private var prevCPU: [pid_t: UInt64] = [:]
    private var prevEnergy: [pid_t: UInt64] = [:]
    private var prevGPU: [pid_t: UInt64] = [:]
    private var prevTime: UInt64 = 0
    private var timebase = mach_timebase_info()
    private let me = getuid()

    public init() { mach_timebase_info(&timebase) }

    public func sample() -> [ProcInfo] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = prevTime == 0 ? 0 : Double(now &- prevTime)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let count = max(0, Int(got)) / MemoryLayout<pid_t>.size
        let gpuNow = GPUUsage.read()

        var result: [ProcInfo] = []
        var cur: [pid_t: UInt64] = [:], curEnergy: [pid_t: UInt64] = [:]
        var nameBuf = [CChar](repeating: 0, count: 256)
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_taskallinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size else { continue }
            let ticks = info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system
            let ns = ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
            cur[pid] = ns
            var cpu = 0.0
            if elapsed > 0, let p = prevCPU[pid], ns >= p { cpu = Double(ns - p) / elapsed * 100 }

            var energyW: Double?
            if info.pbsd.pbi_uid == me, let e = Self.energyNJ(pid) {
                curEnergy[pid] = e
                if elapsed > 0, let p = prevEnergy[pid], e >= p { energyW = Double(e - p) / elapsed }
            }
            var gpu = 0.0
            if elapsed > 0, let g = gpuNow[pid], let p = prevGPU[pid], g >= p { gpu = Double(g - p) / elapsed }

            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            result.append(ProcInfo(pid: pid, name: String(cString: nameBuf), uid: info.pbsd.pbi_uid, cpu: cpu,
                                   ppid: pid_t(info.pbsd.pbi_ppid), pgid: pid_t(info.pbsd.pbi_pgid),
                                   hasTTY: info.pbsd.e_tdev != UInt32.max, energyW: energyW, gpu: gpu))
        }
        prevCPU = cur
        prevEnergy = curEnergy
        prevGPU = gpuNow
        prevTime = now
        return result
    }

    private static func energyNJ(_ pid: pid_t) -> UInt64? {
        var ri = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return r == 0 ? ri.ri_energy_nj : nil
    }
}

/// Accumulated GPU time per pid from the GPU driver's user clients (what Activity Monitor's GPU column uses).
enum GPUUsage {
    static func read() -> [pid_t: UInt64] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXDeviceUserClient"), &it) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(it) }
        var out: [pid_t: UInt64] = [:]
        while case let e = IOIteratorNext(it), e != 0 {
            defer { IOObjectRelease(e) }
            // "pid 412, runningboardd"
            guard let creator = IORegistryEntryCreateCFProperty(e, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let pid = creator.split(separator: ",").first?.split(separator: " ").last.flatMap({ pid_t($0) }),
                  let usage = IORegistryEntryCreateCFProperty(e, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]] else { continue }
            let t = usage.reduce(UInt64(0)) { $0 &+ ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
            out[pid, default: 0] &+= t
        }
        return out
    }
}
