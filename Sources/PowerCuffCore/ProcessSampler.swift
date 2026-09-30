import Foundation
import Darwin

public struct ProcInfo: Sendable {
    public let pid: pid_t
    public let name: String
    public let uid: uid_t
    /// Percent of one core over the last sample interval (150 = 1.5 cores).
    public let cpu: Double
}

/// Per-process CPU usage from libproc deltas. Not thread-safe; use from one queue.
public final class ProcessSampler {
    private var prevCPU: [pid_t: UInt64] = [:]
    private var prevTime: UInt64 = 0
    private var timebase = mach_timebase_info()

    public init() { mach_timebase_info(&timebase) }

    public func sample() -> [ProcInfo] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = prevTime == 0 ? 0 : Double(now &- prevTime)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let count = max(0, Int(got)) / MemoryLayout<pid_t>.size

        var result: [ProcInfo] = []
        var cur: [pid_t: UInt64] = [:]
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
            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            result.append(ProcInfo(pid: pid, name: String(cString: nameBuf), uid: info.pbsd.pbi_uid, cpu: cpu))
        }
        prevCPU = cur
        prevTime = now
        return result
    }
}
