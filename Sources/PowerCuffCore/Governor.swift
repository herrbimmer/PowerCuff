import Foundation

public struct ProcRow: Identifiable, Sendable, Equatable {
    public var id: pid_t
    public var name: String
    /// Unthrottled CPU demand, percent of one core.
    public var demandCPU: Double
    public var estWatts: Double
    /// 1 = running freely.
    public var duty: Double
    public var throttleable: Bool
    public var excluded: Bool

    public init(id: pid_t, name: String, demandCPU: Double, estWatts: Double, duty: Double,
                throttleable: Bool, excluded: Bool) {
        self.id = id; self.name = name; self.demandCPU = demandCPU; self.estWatts = estWatts
        self.duty = duty; self.throttleable = throttleable; self.excluded = excluded
    }
}

public enum GovernorState: Equatable, Sendable {
    case off, noData, underCap, limiting(Int), cannotReach
}

public struct GovernorReport: Sendable, Equatable {
    public var state: GovernorState = .off
    public var reductionW: Double = 0
    public var unmetW: Double = 0
    public var procs: [ProcRow] = []

    public init(state: GovernorState = .off, reductionW: Double = 0, unmetW: Double = 0, procs: [ProcRow] = []) {
        self.state = state; self.reductionW = reductionW; self.unmetW = unmetW; self.procs = procs
    }
}

/// Closed-loop power governor. Confined to one queue; call `tick` about once per second.
public final class Governor: @unchecked Sendable {
    public static let defaultExcluded: Set<String> = [
        "WindowServer", "kernel_task", "loginwindow", "Finder", "Dock", "SystemUIServer", "PowerCuff",
        "launchd", "coreaudiod", "bluetoothd", "audiomxd", "ControlCenter", "Control Center",
        "NotificationCenter", "universalaccessd", "hidd", "sh", "login", "zsh", "bash",
    ]

    private let sampler = ProcessSampler()
    private let engine = ThrottleEngine()
    private var controller = ReductionController()
    private var smoothed: Double?
    private var lastTick: Date?
    private var engaged = false
    private var lastDuties: [pid_t: Double] = [:]
    private var floorW = 8.0
    private var minSystemW = 12.0
    private var kSmooth: Double?
    private var lastUnmet = 0.0
    private var unmetTicks = 0
    private var warm = false
    private var useBackground = false
    private let me = getuid()
    private let selfPID = getpid()

    /// Watts of margin kept below the cap.
    public var marginW = 2.0
    static let debug = ProcessInfo.processInfo.environment["POWERCUFF_DEBUG"] != nil

    public init() {}

    private let stateLock = NSLock()
    private var stopped = false
    private var isStopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopped }

    /// Final release for quitting. Safe from any thread; later `tick`s are inert and never throttle again.
    public func shutdown() {
        stateLock.lock(); stopped = true; stateLock.unlock()
        engine.releaseAll()
    }

    /// Drops every throttle now (e.g. before sleep) but keeps the governor usable.
    public func releaseThrottles() {
        engine.apply(duties: [:])
        lastDuties = [:]; lastUnmet = 0; unmetTicks = 0; useBackground = false; engaged = false
        controller.reset()
    }

    public func tick(snapshot: PowerSnapshot?, capW: Double, enabled: Bool, frontmostPID: pid_t?,
                     excluded: Set<String>, now: Date = Date()) -> GovernorReport {
        if isStopped { return GovernorReport(state: .off) }
        let procs = sampler.sample()
        let dt = min(max(now.timeIntervalSince(lastTick ?? now.addingTimeInterval(-1)), 0.2), 3)
        lastTick = now

        guard let snap = snapshot else {
            release()
            return GovernorReport(state: .noData, procs: rows(procs, [:], excluded, watts: 0))
        }
        let sumCPU = procs.reduce(0) { $0 + $1.cpu }
        // First sample has no CPU deltas yet; measure only.
        let firstTick = !warm
        warm = true
        if snap.systemW > 3 {
            // Idle floor: lowest load seen, creeping up 1.2 W/min so it can follow brightness changes.
            minSystemW = min(snap.systemW, minSystemW + 0.02 * dt)
            floorW = min(max(minSystemW * 0.9, 4), 25)
        }

        let raw = snap.controlledW
        smoothed = smoothed.map { $0 * 0.4 + raw * 0.6 } ?? raw
        guard enabled else {
            release()
            return GovernorReport(state: .off, procs: rows(procs, [:], excluded, watts: 0))
        }

        if firstTick { return GovernorReport(state: .underCap, procs: rows(procs, [:], excluded, watts: 0)) }
        let target = max(capW - marginW, 1)
        let reduction = controller.update(controlledW: smoothed ?? raw, targetW: target, dt: dt, freeze: lastUnmet > 0.5)
        if engaged { engaged = reduction > 0.1 } else { engaged = reduction > 0.5 }
        guard engaged else {
            release()
            return GovernorReport(state: .underCap, reductionW: reduction,
                                  procs: rows(procs, [:], excluded, watts: wattsPerCPU(snap, sumCPU)))
        }

        let kRaw = wattsPerCPU(snap, sumCPU)
        let k = kSmooth.map { $0 * 0.7 + kRaw * 0.3 } ?? kRaw
        kSmooth = k
        let skip = Governor.defaultExcluded.union(excluded)
        var loads: [LoadEntry] = []
        for p in procs where isEligible(p, skip) {
            let demand = p.cpu / max(lastDuties[p.pid] ?? 1, 0.05)
            guard demand >= 2 else { continue }
            loads.append(LoadEntry(pid: p.pid, watts: k * demand, tier: p.pid == frontmostPID ? 1 : 0))
        }
        let (duties, unmet) = Allocator.duties(reductionW: reduction, loads: loads)
        if Governor.debug {
            let d = duties.values.map { String(format: "%.2f", $0) }.joined(separator: ",")
            FileHandle.standardError.write(Data(String(format: "ctl=%.1f smooth=%.1f target=%.1f R=%.2f k=%.3f floor=%.1f n=%d unmet=%.1f duties=[%@]\n",
                raw, smoothed ?? 0, target, reduction, k, floorW, loads.count, unmet, d).utf8))
        }
        lastDuties = duties
        lastUnmet = unmet
        unmetTicks = unmet > 0.5 ? unmetTicks + 1 : 0
        if unmetTicks >= 3 { useBackground = true }   // duty-cycling alone can't reach the cap
        engine.apply(duties: duties, background: useBackground)

        let limiting = duties.values.filter { $0 < 0.98 }.count
        let state: GovernorState = unmet > 0.5 ? .cannotReach : .limiting(limiting)
        return GovernorReport(state: state, reductionW: reduction, unmetW: unmet,
                              procs: rows(procs, duties, excluded, watts: k))
    }

    // MARK: helpers

    private func release() {
        if !lastDuties.isEmpty { engine.apply(duties: [:]) }
        lastDuties = [:]
        lastUnmet = 0
        unmetTicks = 0
        useBackground = false
        if !engaged { controller.reset() }
    }

    private func isEligible(_ p: ProcInfo, _ skip: Set<String>) -> Bool {
        p.uid == me && p.pid > 1 && p.pid != selfPID && !skip.contains(p.name)
    }

    /// Watts attributed per percent of one core, from the dynamic part of system load.
    private func wattsPerCPU(_ snap: PowerSnapshot, _ sumCPU: Double) -> Double {
        max(snap.systemW - floorW, 0) / max(sumCPU, 30)
    }

    private func rows(_ procs: [ProcInfo], _ duties: [pid_t: Double], _ excluded: Set<String>,
                      watts k: Double) -> [ProcRow] {
        let skip = Governor.defaultExcluded.union(excluded)
        return procs.map { p in
            let duty = duties[p.pid] ?? 1
            let demand = p.cpu / max(duty, 0.05)
            return ProcRow(id: p.pid, name: p.name, demandCPU: demand, estWatts: k * demand, duty: duty,
                           throttleable: isEligible(p, skip), excluded: excluded.contains(p.name))
        }
        .sorted { $0.demandCPU > $1.demandCPU }
        .prefix(8).map { $0 }
    }
}
