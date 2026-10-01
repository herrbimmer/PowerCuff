import Foundation
import Darwin

// MARK: - Crash / kill safety

/// Throttle units currently held: pids, or negative process-group ids (`kill(-pgid, …)` reaches the whole group).
private var gUnits = UnsafeMutablePointer<Int32>.allocate(capacity: 512)
private var gUnitCount: Int = 0
private var gInstalled = false

private func emergencyResume(_ sig: Int32) {
    var i = 0
    while i < gUnitCount {
        let u = gUnits[i]
        kill(u, SIGCONT)
        if u > 0 { setpriority(PRIO_DARWIN_PROCESS, id_t(u), 0) }   // leave background QoS
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

    static func publish(_ units: [pid_t]) {
        let n = min(units.count, 512)
        for i in 0..<n { gUnits[i] = units[i] }
        gUnitCount = n
        try? units.map(String.init).joined(separator: "\n").write(toFile: stateFile, atomically: true, encoding: .utf8)
    }

    /// Resumes and un-backgrounds anything a previous (killed) run left behind.
    static func recoverStale() {
        guard let text = try? String(contentsOfFile: stateFile, encoding: .utf8) else { return }
        for u in text.split(separator: "\n").compactMap({ pid_t($0) }) where abs(u) > 1 {
            kill(u, SIGCONT)
            for pid in u > 0 ? [u] : ProcGroup.members(-u) { setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0) }
        }
        try? FileManager.default.removeItem(atPath: stateFile)
    }
}

enum ProcGroup {
    static func members(_ pgid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 1024)
        let got = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(0, Int(got)) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }
}

// MARK: - Engine

public struct ThrottleOrder: Sendable, Equatable {
    /// Fraction of each period the unit may run (1 = only demote priority).
    public var duty: Double
    /// Also demote to background QoS (E-cores only): cuts peak power, not just the average.
    public var background: Bool
    public init(duty: Double, background: Bool = false) { self.duty = duty; self.background = background }
}

/// Duty-cycles throttle units with SIGSTOP/SIGCONT (100 ms period, staggered run windows) and demotes them to
/// background QoS. A unit is a pid or a whole process group (negative id): group members are re-listed every
/// period, so short-lived children (compiler jobs, browser helpers) are caught within 100 ms.
public final class ThrottleEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.powercuff.throttle", qos: .userInteractive)
    private var orders: [pid_t: ThrottleOrder] = [:]
    /// Never stopped (job leaders of an interactive shell: stopping them makes the shell report "suspended").
    private var protected: Set<pid_t> = []
    private var skipNames: Set<String> = []
    private var members: [pid_t: [pid_t]] = [:]
    private var allowed: [pid_t: Bool] = [:]
    private var backgrounded: [pid_t: pid_t] = [:]        // pid -> unit
    private var timer: DispatchSourceTimer?
    private var watchdog: Process?
    private var stopped = false
    private var generation = 0
    private let period = 0.1
    private let me = getuid()
    private let selfPID = getpid()

    public init() {
        ThrottleSafety.installOnce()
        ThrottleSafety.recoverStale()
    }

    /// `orders`: unit -> order. Units absent are released.
    public func apply(_ new: [pid_t: ThrottleOrder], protected: Set<pid_t> = [], skipNames: Set<String> = []) {
        queue.async { self.applyLocked(new, protected: protected, skipNames: skipNames) }
    }

    /// Convenience for single pids.
    public func apply(duties: [pid_t: Double], background: Bool = false) {
        apply(duties.mapValues { ThrottleOrder(duty: $0, background: background) })
    }

    /// Final release for quitting: resumes and un-backgrounds everything, then refuses further throttling.
    public func releaseAll() {
        queue.sync {
            self.stopped = true
            self.applyLocked([:], protected: [], skipNames: [])
            self.stopWatchdog()
            try? FileManager.default.removeItem(atPath: ThrottleSafety.stateFile)
        }
    }

    public var throttledCount: Int { queue.sync { orders.values.filter { $0.duty < 0.995 }.count } }

    private func applyLocked(_ new: [pid_t: ThrottleOrder], protected: Set<pid_t>, skipNames: Set<String>) {
        guard !stopped || new.isEmpty else { return }
        for pid in protected.subtracting(self.protected) { kill(pid, SIGCONT) }
        self.protected = protected
        if skipNames != self.skipNames { self.skipNames = skipNames; allowed = [:] }
        for unit in orders.keys where new[unit] == nil { release(unit) }
        let changed = Set(orders.keys) != Set(new.keys)
        orders = new
        for (unit, o) in new where !o.background { unbackground(unit) }
        if !stopped && changed { ThrottleSafety.publish(Array(orders.keys)) }
        if orders.isEmpty { timer?.cancel(); timer = nil } else { startTimer(); startWatchdog() }
    }

    private func release(_ unit: pid_t) {
        kill(unit, SIGCONT)
        for pid in members[unit] ?? [] { kill(pid, SIGCONT) }
        unbackground(unit)
        members[unit] = nil
    }

    private func unbackground(_ unit: pid_t) {
        for (pid, u) in backgrounded where u == unit {
            setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0)
            backgrounded[pid] = nil
        }
    }

    /// Processes of the unit we may act on: own user, not us, not excluded by name. (Protected ones are
    /// demoted but never stopped.)
    private func resolve(_ unit: pid_t) -> [pid_t] {
        let pids = unit > 0 ? [unit] : ProcGroup.members(-unit)
        return pids.filter { pid in
            guard pid != selfPID else { return false }
            if let ok = allowed[pid] { return ok }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            var ok = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size && info.pbsi_uid == me
            if ok {
                var buf = [CChar](repeating: 0, count: 256)
                proc_name(pid, &buf, UInt32(buf.count))
                ok = !skipNames.contains(String(cString: buf))
            }
            allowed[pid] = ok
            return ok
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: period, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func send(_ unit: pid_t, _ sig: Int32) {
        for pid in members[unit] ?? [] where sig != SIGSTOP || !protected.contains(pid) { kill(pid, sig) }
    }

    private func tick() {
        generation &+= 1
        let gen = generation
        var live: Set<pid_t> = []
        for (unit, o) in orders {
            let pids = resolve(unit)
            if pids.isEmpty && kill(unit, 0) != 0 && errno == ESRCH { orders[unit] = nil; members[unit] = nil; continue }
            members[unit] = pids
            live.formUnion(pids)
            if o.background {
                for pid in pids where backgrounded[pid] == nil {
                    setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG)
                    backgrounded[pid] = unit
                }
            }
        }
        allowed = allowed.filter { live.contains($0.key) }
        backgrounded = backgrounded.filter { live.contains($0.key) || kill($0.key, 0) == 0 }

        let cycling = orders.filter { $0.value.duty < 0.995 }.map { (id: $0.key, duty: max($0.value.duty, 0.03)) }
        let starts = Phases.starts(cycling)
        for (unit, o) in orders {
            guard let start = starts[unit] else { send(unit, SIGCONT); continue }
            let spans = Phases.intervals(start: start, duty: max(o.duty, 0.03))
            send(unit, spans.contains { $0.on == 0 } ? SIGCONT : SIGSTOP)
            for s in spans {
                if s.on > 0 { at(s.on, gen) { $0.send(unit, SIGCONT) } }
                if s.off < 1 { at(s.off, gen) { $0.send(unit, SIGSTOP) } }
            }
        }
    }

    /// Runs `body` at `fraction` of the current period unless a newer period (or a release) superseded it.
    private func at(_ fraction: Double, _ gen: Int, _ body: @escaping (ThrottleEngine) -> Void) {
        queue.asyncAfter(deadline: .now() + fraction * period) { [weak self] in
            guard let self, self.generation == gen, !self.stopped else { return }
            body(self)
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        // Entries are pids or negative pgids; `kill -CONT -- -N` resumes a whole group.
        let script = #"P=$1; F=$2; while kill -0 $P 2>/dev/null; do sleep 0.5; done; for u in $(cat "$F" 2>/dev/null); do kill -CONT -- $u 2>/dev/null; case $u in -*) for q in $(pgrep -g ${u#-}); do taskpolicy -B -p $q 2>/dev/null; done;; *) taskpolicy -B -p $u 2>/dev/null;; esac; done"#
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
