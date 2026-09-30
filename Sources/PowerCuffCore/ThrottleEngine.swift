import Foundation
import Darwin

// MARK: - Crash / kill safety

private var gPids = UnsafeMutablePointer<Int32>.allocate(capacity: 512)
private var gPidCount: Int = 0
private var gInstalled = false

private func emergencyResume(_ sig: Int32) {
    var i = 0
    while i < gPidCount {
        kill(gPids[i], SIGCONT)
        setpriority(PRIO_DARWIN_PROCESS, id_t(gPids[i]), 0)   // leave background QoS
        i += 1
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

/// Guarantees throttled processes are never left stopped: signal handlers for catchable exits,
/// a shell watchdog for SIGKILL/crash, and a stale-state sweep at launch.
enum ThrottleSafety {
    static let stateDir = NSHomeDirectory() + "/Library/Application Support/PowerCuff"
    static let stateFile = stateDir + "/throttled.pids"

    static func installOnce() {
        guard !gInstalled else { return }
        gInstalled = true
        for s in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP] {
            signal(s, emergencyResume)
        }
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    }

    static func publish(_ pids: [pid_t]) {
        let n = min(pids.count, 512)
        for i in 0..<n { gPids[i] = pids[i] }
        gPidCount = n
        try? pids.map(String.init).joined(separator: "\n").write(toFile: stateFile, atomically: true, encoding: .utf8)
    }

    /// Resumes and un-backgrounds anything a previous (killed) run left behind.
    static func recoverStale() {
        guard let text = try? String(contentsOfFile: stateFile, encoding: .utf8) else { return }
        for pid in text.split(separator: "\n").compactMap({ pid_t($0) }) where pid > 1 {
            kill(pid, SIGCONT)
            setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0)
        }
        try? FileManager.default.removeItem(atPath: stateFile)
    }
}

// MARK: - Engine

/// Duty-cycles processes with SIGSTOP/SIGCONT (100 ms period) and demotes them to background QoS.
public final class ThrottleEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.powercuff.throttle", qos: .userInteractive)
    private var duties: [pid_t: Double] = [:]
    private var backgrounded: Set<pid_t> = []
    private var timer: DispatchSourceTimer?
    private var watchdog: Process?
    private var stopped = false
    private let period = 0.1

    public init() {
        ThrottleSafety.installOnce()
        ThrottleSafety.recoverStale()
    }

    /// `duties`: pid -> fraction of time allowed to run (1 = only demote priority). Pids absent are released.
    /// `background`: also demote to background QoS (E-cores only) - a coarse, last-resort lever.
    public func apply(duties new: [pid_t: Double], background: Bool = false) {
        queue.async { self.applyLocked(new, background: background) }
    }

    /// Final release for quitting: resumes and un-backgrounds everything, then refuses further throttling.
    public func releaseAll() {
        queue.sync {
            self.stopped = true
            self.applyLocked([:], background: false)
            self.stopWatchdog()
            try? FileManager.default.removeItem(atPath: ThrottleSafety.stateFile)
        }
    }

    public var throttledCount: Int { queue.sync { duties.values.filter { $0 < 0.995 }.count } }

    private func applyLocked(_ new: [pid_t: Double], background: Bool) {
        guard !stopped || new.isEmpty else { return }
        for pid in duties.keys where new[pid] == nil { release(pid) }
        for (pid, d) in new {
            duties[pid] = d
            if background, !backgrounded.contains(pid) {
                setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG)
                backgrounded.insert(pid)
            } else if !background, backgrounded.remove(pid) != nil {
                setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0)
            }
        }
        if !stopped { ThrottleSafety.publish(Array(duties.keys)) }
        if duties.isEmpty { timer?.cancel(); timer = nil } else { startTimer(); startWatchdog() }
    }

    private func release(_ pid: pid_t) {
        kill(pid, SIGCONT)
        if backgrounded.remove(pid) != nil { setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0) }
        duties[pid] = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: period, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        var gone: [pid_t] = []
        for (pid, d) in duties {
            if kill(pid, SIGCONT) != 0 && errno == ESRCH { gone.append(pid); continue }
            if d < 0.995 {
                queue.asyncAfter(deadline: .now() + max(0.003, d * period)) { [weak self] in
                    guard let self, let cur = self.duties[pid], cur < 0.995 else { return }
                    kill(pid, SIGSTOP)
                }
            }
        }
        for pid in gone { duties[pid] = nil; backgrounded.remove(pid) }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let script = #"P=$1; F=$2; while kill -0 $P 2>/dev/null; do sleep 0.5; done; for p in $(cat "$F" 2>/dev/null); do kill -CONT $p 2>/dev/null; taskpolicy -B -p $p 2>/dev/null; done"#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(getpid()), ThrottleSafety.stateFile]
        p.standardOutput = nil; p.standardError = nil
        if (try? p.run()) != nil { watchdog = p }
    }

    private func stopWatchdog() {
        watchdog?.terminate()
        watchdog = nil
    }
}
