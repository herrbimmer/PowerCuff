import Foundation

public struct ProcRow: Identifiable, Sendable, Equatable {
    public var id: pid_t
    public var name: String
    /// Unthrottled CPU demand, percent of one core.
    public var demandCPU: Double
    /// Unthrottled draw attributed to this process, wall watts.
    public var estWatts: Double
    /// Draw right now, wall watts.
    public var watts: Double
    /// 1 = running freely.
    public var duty: Double
    public var background: Bool
    public var throttleable: Bool
    public var excluded: Bool

    public init(id: pid_t, name: String, demandCPU: Double, estWatts: Double, watts: Double = 0, duty: Double,
                background: Bool = false, throttleable: Bool, excluded: Bool) {
        self.id = id; self.name = name; self.demandCPU = demandCPU; self.estWatts = estWatts; self.watts = watts
        self.duty = duty; self.background = background; self.throttleable = throttleable; self.excluded = excluded
    }
}

public enum GovernorState: Equatable, Sendable {
    case off, noData, underCap, limiting(Int), cannotReach
}

/// Levers in effect beyond process throttling.
public struct LeverState: Equatable, Sendable {
    public var chargePaused = false
    /// Brightness the governor dimmed the panel to (0...1), nil when untouched.
    public var dimmedTo: Double?
    public var lowPower = false
    /// Adapter input switched off by the helper: the Mac runs from the battery.
    public var onBattery = false
    public init() {}
}

public struct GovernorConfig: Sendable, Equatable {
    public var capW = 60.0
    public var enabled = false
    /// Holds peaks (not just the average) under the cap: wider adaptive margin, E-cores first, quicker escalation.
    public var strict = false
    public var excluded: Set<String> = []
    /// Lowest brightness the governor may dim to; nil = never touch the display.
    public var dimFloor: Double? = 0.4
    public var pauseCharging = true
    public var lowPowerMode = true
    /// Last resort: switch the adapter off and run from the battery.
    public var batteryBackstop = true
    /// Fixed adapter efficiency (user calibration); nil = model.
    public var efficiency: Double?
    public init() {}
}

public struct GovernorReport: Sendable, Equatable {
    public var state: GovernorState = .off
    public var reductionW: Double = 0
    public var unmetW: Double = 0
    /// Fast (≈250 ms) estimate of the capped quantity, watts.
    public var estW: Double?
    public var targetW: Double?
    public var levers = LeverState()
    public var helper: HelperStatus = .notInstalled
    public var procs: [ProcRow] = []

    public init(state: GovernorState = .off, reductionW: Double = 0, unmetW: Double = 0, procs: [ProcRow] = []) {
        self.state = state; self.reductionW = reductionW; self.unmetW = unmetW; self.procs = procs
    }
}

/// Closed-loop power governor. Confined to one queue; call `tick` at 5 Hz while enforcing (1 Hz otherwise).
///
/// Control signal: the SMC rails (exact, 1 update/s) corrected at 5 Hz by the SoC energy counters, so a burst
/// is seen within ~250 ms. Levers, cheapest first: pause charging → duty-cycle/demote the processes drawing the
/// most (by measured energy, CPU + GPU) → dim the display → Low Power Mode → run from the battery.
public final class Governor: @unchecked Sendable {
    public static let defaultExcluded: Set<String> = Set([
        "WindowServer", "kernel_task", "loginwindow", "Finder", "Dock", "SystemUIServer", "PowerCuff",
        "launchd", "coreaudiod", "bluetoothd", "audiomxd", "ControlCenter", "Control Center",
        "NotificationCenter", "universalaccessd", "hidd", "login",
    ]).union(shells)
    static let shells: Set<String> = ["sh", "zsh", "bash", "fish", "dash", "ksh", "tcsh", "csh"]

    private struct Unit {
        var id: pid_t
        var measuredW = 0.0          // SoC-side watts drawn over the last sampling interval
        var demandW = 0.0            // what it would draw unthrottled
        var cpu = 0.0
        var tier = 0
    }

    private enum Lever: Int, Comparable {
        case dim = 1, lowPower, battery
        static func < (a: Lever, b: Lever) -> Bool { a.rawValue < b.rawValue }
        var hold: Double { self == .dim ? 5 : self == .lowPower ? 15 : 20 }
    }

    private let sampler = ProcessSampler()
    private let engine = ThrottleEngine()
    private let meter: EnergyMeter?
    private let dimmer: DisplayDimmer
    private let helper: HelperLink
    private var controller = ReductionController.fast
    private var fastMode = true
    private var meterInterval = 0.0
    private var hasDisplay = false
    private let lock = NSLock()
    private var stopped = false
    private var warm = false
    private var wantFastRefresh = false
    private var relaxed = false
    private var processesExhausted = true
    private var lastTick: Date?
    private var lastSample: Date?

    // process picture, refreshed about once a second
    private var procs: [ProcInfo] = []
    private var units: [Unit] = []
    private var unitOf: [pid_t: pid_t] = [:]
    private var protectedPids: Set<pid_t> = []
    private var rowsCache: [ProcRow] = []
    /// System watts per fully busy core, per unit, learned while the unit runs almost unthrottled (energy is not
    /// linear in duty: every short run window pays to wake and ramp the cluster).
    private var wattsPerCore: [pid_t: Double] = [:]
    private var avgWattsPerCore = 2.2
    /// Time-weighted throttle since the last process refresh: seconds of "1 - duty" per unit, and total seconds.
    private var dutyDeficit: [pid_t: Double] = [:]
    /// Seconds each unit spent demoted to the E-cores since the last refresh (its power per core is not comparable).
    private var backgroundTime: [pid_t: Double] = [:]
    private var dutyTime = 0.0
    /// System watts per SoC watt (IOReport): fans, VRM and fabric losses make the whole machine move about
    /// twice as much as the SoC counters. Learned online by ridge regression of PSTR on the SoC total.
    private(set) var gain = 2.0
    private var gainPairs: [(x: Double, y: Double)] = []
    private var lastGainAt: Date?
    private var floorW = 8.0
    private var minSystemW = 12.0

    // control state
    private var offset: Double?
    private var estHistory: [(t: Date, w: Double)] = []
    private var engaged = false
    private var lastNeed: Date?
    private var orders: [pid_t: ThrottleOrder] = [:]
    private var lastUnmet = 0.0
    private var unmetSince: Date?
    private var level: Lever?
    private var overSince: Date?
    private var calmSince: Date?
    private var leverSince: Date?
    private var leverGain: [Lever: Double] = [.dim: 3, .lowPower: 8, .battery: 0]
    private var estAtEscalation: Double?
    private var chargePaused = false
    private var chargePausedAt: Date?
    private var lastChargeW = 10.0
    private var applied = HelperProtocol.Levers()
    private let me = getuid()
    private let selfPID = getpid()
    private let selfPGID = getpgrp()

    /// Minimum watts of margin kept below the cap (strict mode adds the measured ripple on top).
    public var marginW = 1.5
    static let debug = ProcessInfo.processInfo.environment["POWERCUFF_DEBUG"] != nil

    public init(meter: EnergyMeter? = EnergyMeter.shared, dimmer: DisplayDimmer = DisplayDimmer(),
                helper: HelperLink = HelperLink()) {
        self.meter = meter?.available == true ? meter : nil
        self.dimmer = dimmer
        self.helper = helper
        fastMode = self.meter != nil
        controller = fastMode ? .fast : .slow
    }

    /// Seconds between ticks the caller should use: 5 Hz while enforcing or near the cap, 2 Hz when far below it.
    public func interval(enabled: Bool) -> Double {
        guard enabled && fastMode else { return 1 }
        return relaxed ? 0.5 : 0.2
    }

    /// Final release for quitting. Safe from any thread; later `tick`s are inert and never throttle again.
    /// Also drops the helper link, which makes the helper undo anything it still holds.
    public func shutdown() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        engine.releaseAll()
        dimmer.restoreAll()
        helper.release()
    }

    /// Drops every lever now (e.g. before sleep) but keeps the governor usable.
    public func releaseThrottles() {
        lock.lock(); defer { lock.unlock() }
        releaseAll()
        helper.release()
    }

    public func tick(snapshot: PowerSnapshot?, config: GovernorConfig, frontmostPID: pid_t?, now: Date = Date()) -> GovernorReport {
        lock.lock(); defer { lock.unlock() }
        if stopped { return GovernorReport(state: .off) }
        let dt = min(max(now.timeIntervalSince(lastTick ?? now.addingTimeInterval(-interval(enabled: config.enabled))), 0.05), 3)
        lastTick = now
        dutyTime += dt
        for (id, o) in orders {
            dutyDeficit[id, default: 0] += (1 - o.duty) * dt
            if o.background { backgroundTime[id, default: 0] += dt }
        }
        let period = interval(enabled: config.enabled)
        if period != meterInterval { meter?.setInterval(period); meterInterval = period }
        if fastMode { controller.kDown = config.strict ? 0.15 : 0.3 }

        let skip = Self.defaultExcluded.union(config.excluded)
        // Normally once a second; while over target, every 0.3 s so a new burst is found and held quickly.
        let since = lastSample.map { now.timeIntervalSince($0) } ?? .infinity
        if since >= 0.9 || (wantFastRefresh && since >= 0.3) {
            refreshProcesses(snapshot: snapshot, skip: skip, excluded: config.excluded, frontmostPID: frontmostPID)
            lastSample = now
        }

        guard let snap = snapshot else {
            releaseAll()
            return report(.noData, config: config)
        }
        if snap.systemW > 3 {
            // Idle floor: lowest load seen, creeping up 1.2 W/min so it can follow brightness changes.
            minSystemW = min(snap.systemW, minSystemW + 0.02 * dt)
            floorW = min(max(minSystemW * 0.9, 4), 25)
        }

        learnGain(snap: snap, now: now)

        // While the helper has the adapter switched off the wall reads 0; what counts is what it would draw.
        let onBattery = applied.adapterOff
        let factor = onBattery ? wallFactor(snap.systemW, snap, config) : snap.wallFactor
        let slowW = onBattery ? snap.systemW * factor : snap.controlledW
        let est = estimate(slowW: slowW, factor: factor, dt: dt)
        estHistory.append((now, est))
        estHistory.removeAll { now.timeIntervalSince($0.t) > 5 }

        guard config.enabled else {
            releaseAll()
            relaxed = false
            return report(.off, config: config, est: est)
        }
        // First pass has no CPU/energy deltas yet; measure only.
        guard warm else { warm = true; return report(.underCap, config: config, est: est) }

        // Ripple = 2σ of the estimate over the last seconds: what a peak typically sits above the mean.
        let mean = estHistory.reduce(0) { $0 + $1.w } / Double(estHistory.count)
        let sigma = (estHistory.reduce(0) { $0 + ($1.w - mean) * ($1.w - mean) } / Double(estHistory.count)).squareRoot()
        let ripple = min(2 * sigma, 6)
        let target = max(config.capW - (config.strict ? marginW + 0.5 + ripple : marginW + 0.5 * ripple), 1)

        // 1. Charging: the cheapest lever, it costs no performance.
        updateCharging(snap: snap, est: est, target: target, factor: factor, config: config, now: now)

        // 2. Processes.
        let loads = units.compactMap { u -> LoadEntry? in
            let w = demand(u) * factor
            return w >= 0.3 ? LoadEntry(pid: u.id, watts: w, tier: u.tier) : nil
        }
        let shedable = loads.reduce(0) { $0 + $1.watts } * 0.92
        // What the processes can still give up from where they are now (a unit at minimum duty has nothing left).
        let remaining = units.reduce(0) { $0 + $1.demandW * max((orders[$1.id]?.duty ?? 1) - 0.08, 0) } * factor
        let reduction = controller.update(controlledW: est, targetW: target, dt: dt, limit: shedable)
        if reduction > 0.5 { engaged = true; lastNeed = now }
        // Let go only when running free would still fit: otherwise releasing just brings the overshoot back
        // (a burst every few seconds). What throttling holds back = unthrottled demand − what it draws now.
        let heldBack = units.reduce(0) { $0 + (orders[$1.id] != nil ? max($1.demandW - $1.measuredW, 0) : 0) } * factor
        let wouldBreach = est + heldBack > target + 0.5
        if engaged, reduction < 0.1, !wouldBreach, now.timeIntervalSince(lastNeed ?? now) > (config.strict ? 4 : 2) {
            engaged = false
        }

        var unmet = 0.0, spare = 0.0
        var futile = false
        if engaged {
            // Futile: even stopping every process would shed under a quarter of the overshoot (the rest is
            // charging, display, idle floor). Freezing the machine for a few watts is worse than the overshoot,
            // so leave processes alone and let the other levers (or the user) deal with it.
            let over = est - target
            futile = over > 2 && shedable < 0.25 * over
            if futile {
                releaseProcesses()
                unmet = over
            } else {
                let r = Allocator.duties(reductionW: reduction, loads: loads)
                unmet = r.unmetW
                spare = Allocator.spareW(reductionW: reduction, loads: loads)
                unmetSince = unmet > 0.5 ? (unmetSince ?? now) : nil
                let background = config.strict || unmetSince.map { now.timeIntervalSince($0) > 1.5 } ?? false
                // Strict keeps every held unit on the E-cores (no P↔E cliff as duties relax); normal only the cut ones.
                orders = r.duties.mapValues { ThrottleOrder(duty: $0, background: background && (config.strict || $0 < 0.98)) }
                engine.apply(orders, protected: protectedPids, skipNames: skip)
            }
        } else {
            releaseProcesses()
            spare = shedable
        }
        lastUnmet = unmet

        wantFastRefresh = est > target + 2
        relaxed = !engaged && level == nil && !chargePaused && est < 0.5 * config.capW

        // 3. Display, Low Power Mode, battery: only when the processes can't carry the cut.
        // Processes can't carry it when even giving up everything left still leaves the draw above the target.
        let deficit = est - target - remaining
        // ... and only once every throttled unit is already on the E-cores (the step before the visible levers).
        processesExhausted = loads.isEmpty
            || (!orders.isEmpty && orders.values.allSatisfy { $0.background || $0.duty >= 0.98 })
        updateLevel(est: est, target: target, deficit: deficit, spare: spare, futile: futile, snap: snap, config: config, now: now)
        applyDimming(est: est, target: target, config: config)
        applied = helper.sync(HelperProtocol.Levers(chargeInhibit: chargePaused, adapterOff: level == .battery,
                                                   lowPower: level.map { $0 >= .lowPower } ?? false && config.lowPowerMode))

        if Self.debug {
            FileHandle.standardError.write(Data(String(format: "est=%.1f slow=%.1f target=%.1f ripple=%.1f R=%.2f unmet=%.1f spare=%.1f gain=%.2f level=%d charge=%d units=%d\n",
                est, slowW, target, ripple, reduction, unmet, spare, gain, level?.rawValue ?? 0, chargePaused ? 0 : 1, orders.count).utf8))
        }

        let limiting = orders.values.filter { $0.duty < 0.98 || $0.background }.count
        let state: GovernorState
        if futile && level != .battery { state = .cannotReach }
        else if deficit > 0.5 && est > config.capW && nextLever(after: level, snap: snap, config: config) == nil { state = .cannotReach }
        else if limiting > 0 || level != nil || chargePaused { state = .limiting(limiting) }
        else { state = .underCap }
        var rep = report(state, config: config, est: est)
        rep.reductionW = reduction
        rep.unmetW = unmet
        rep.targetW = target
        return rep
    }

    // MARK: estimate

    /// SMC mean (exact but a second behind) plus the change the SoC counters saw since: `k·soc(now) + offset`,
    /// where the offset (display, SSD, charging, losses) is learned slowly from the SMC.
    private func estimate(slowW: Double, factor: Double, dt: Double) -> Double {
        guard let meter, let fast = meter.read(window: 0.25), let base = meter.read(window: 1.0) else { return slowW }
        let k = factor * gain
        let raw = slowW - k * base.totalW
        let o = offset.map { $0 + (raw - $0) * min(dt / 2.5, 1) } ?? raw
        offset = o
        return max(k * fast.totalW + max(o, 0), 0)
    }

    /// Ridge regression of the SMC system power on the SoC total, one pair per second over the last 90 s.
    /// With a steady load the pairs carry no slope information and the previous gain stays.
    private func learnGain(snap: PowerSnapshot, now: Date) {
        guard let meter, lastGainAt.map({ now.timeIntervalSince($0) >= 1 }) ?? true,
              let soc = meter.read(window: 1.0) else { return }
        lastGainAt = now
        gainPairs.append((soc.totalW, snap.systemW))
        if gainPairs.count > 90 { gainPairs.removeFirst() }
        guard gainPairs.count >= 8 else { return }
        let n = Double(gainPairs.count)
        let mx = gainPairs.reduce(0) { $0 + $1.x } / n, my = gainPairs.reduce(0) { $0 + $1.y } / n
        let sxx = gainPairs.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }
        let sxy = gainPairs.reduce(0) { $0 + ($1.x - mx) * ($1.y - my) }
        let lambda = 40.0                                  // W²: weight of the previous value (moves slowly)
        gain = min(max((sxy + lambda * gain) / (sxx + lambda), 1.5), 3.5)
    }

    private func wallFactor(_ dcW: Double, _ snap: PowerSnapshot, _ config: GovernorConfig) -> Double {
        guard dcW > 1 else { return 1 }
        return AdapterLoss.wallW(dcW: dcW, ratedW: snap.adapterRatedW, volts: snap.adapterVolts,
                                 fixedEfficiency: config.efficiency) / dcW
    }

    // MARK: processes

    private func demand(_ u: Unit) -> Double { u.demandW }

    private func refreshProcesses(snapshot: PowerSnapshot?, skip: Set<String>, excluded: Set<String>, frontmostPID: pid_t?) {
        procs = sampler.sample()
        hasDisplay = dimmer.current != nil
        let names = Dictionary(procs.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
        let soc = meter?.read(window: 1.0)
        let gpuTotal = procs.reduce(0) { $0 + $1.gpu }
        let cpuScale = soc.map { min(max(1 + ($0.dramW + $0.aneW) / max($0.cpuW, 0.5), 1), 2) } ?? 1
        let sumCPU = procs.reduce(0) { $0 + $1.cpu }
        let k = snapshot.map { max($0.systemW - floorW, 0) / max(sumCPU, 30) } ?? 0    // fallback without IOReport

        // System watts attributable to a process: its share of the SoC counters times the learned gain.
        let g = gain
        func socW(_ p: ProcInfo) -> Double {
            guard let soc, let e = p.energyW else { return k * p.cpu }
            return (e * cpuScale + (gpuTotal > 0 ? soc.gpuW * p.gpu / gpuTotal : 0)) * g
        }

        // Job leaders of an interactive shell can't be stopped (the shell would report "suspended").
        protectedPids = []
        for p in procs where p.uid == me && p.hasTTY {
            if let parent = names[p.ppid], Self.shells.contains(parent) { protectedPids.insert(p.pid) }
        }

        // A process group moves as one unit only when EVERY member may be throttled: one excluded or foreign
        // member (a shell, the terminal, another user's process) keeps the whole group as individual pids,
        // so nothing outside the user's heavy processes is ever stopped by association.
        var groupOK: [pid_t: Bool] = [:]
        var groupSize: [pid_t: Int] = [:]
        for p in procs where p.pgid > 1 {
            groupSize[p.pgid, default: 0] += 1
            let ok = p.uid == me && p.pid != selfPID && !skip.contains(p.name) && !protectedPids.contains(p.pid)
            groupOK[p.pgid] = (groupOK[p.pgid] ?? true) && ok
        }
        let frontPGID = procs.first { $0.pid == frontmostPID }?.pgid

        var byUnit: [pid_t: Unit] = [:]
        unitOf = [:]
        for p in procs where p.uid == me && p.pid > 1 && p.pid != selfPID {
            guard !skip.contains(p.name) else { continue }
            let grouped = p.pgid > 1 && p.pgid != selfPGID && groupOK[p.pgid] == true && (groupSize[p.pgid] ?? 0) > 1
            let id = grouped ? -p.pgid : p.pid
            unitOf[p.pid] = id
            var u = byUnit[id] ?? Unit(id: id)
            u.measuredW += socW(p)
            u.cpu += p.cpu
            if p.pid == frontmostPID || (grouped && p.pgid == frontPGID) { u.tier = 1 }
            byUnit[id] = u
        }
        // Unthrottled demand = cores it would keep busy (CPU time scales linearly with duty) × watts per core,
        // learned while it runs nearly free.
        let span = max(dutyTime, 0.2)
        for id in Array(byUnit.keys) {
            var u = byUnit[id]!
            let meanDuty = max(1 - (dutyDeficit[id] ?? 0) / span, 0.05)
            let busy = u.cpu / 100
            if meanDuty >= 0.6, busy >= 0.05, (backgroundTime[id] ?? 0) == 0 {
                let w = u.measuredW / busy
                wattsPerCore[id] = wattsPerCore[id].map { $0 * 0.5 + w * 0.5 } ?? w
                if busy >= 0.5 { avgWattsPerCore = avgWattsPerCore * 0.9 + w * 0.1 }
            }
            u.demandW = busy / meanDuty * (wattsPerCore[id] ?? avgWattsPerCore)
            byUnit[id] = u
        }
        wattsPerCore = wattsPerCore.filter { byUnit[$0.key] != nil }
        if Self.debug {
            for u in byUnit.values.sorted(by: { $0.demandW > $1.demandW }).prefix(4) where u.demandW > 0.3 {
                FileHandle.standardError.write(Data(String(format: "  unit %d measured=%.2f meanDuty=%.2f demand=%.2f w/core=%.2f cpu=%.0f%% members=%@\n",
                    u.id, u.measuredW, 1 - (dutyDeficit[u.id] ?? 0) / span, u.demandW, wattsPerCore[u.id] ?? avgWattsPerCore, u.cpu,
                    procs.filter { unitOf[$0.pid] == u.id }.map(\.name).prefix(3).joined(separator: ",")).utf8))
            }
        }
        dutyDeficit = [:]; backgroundTime = [:]; dutyTime = 0
        units = Array(byUnit.values)

        let factor = snapshot?.wallFactor ?? 1
        rowsCache = procs.map { p in
            let unit = unitOf[p.pid]
            let o = unit.flatMap { orders[$0] }
            let duty = o?.duty ?? 1
            let w = socW(p) * factor
            return ProcRow(id: p.pid, name: p.name, demandCPU: p.cpu / max(duty, 0.05), estWatts: w / max(duty, 0.05),
                           watts: w, duty: duty, background: o?.background ?? false, throttleable: unit != nil,
                           excluded: excluded.contains(p.name))
        }
        .sorted { $0.estWatts > $1.estWatts }
        .prefix(8).map { $0 }
    }

    private func releaseProcesses() {
        if !orders.isEmpty { engine.apply([:]) }
        orders = [:]
        unmetSince = nil
    }

    // MARK: levers

    private func updateCharging(snap: PowerSnapshot, est: Double, target: Double, factor: Double,
                                config: GovernorConfig, now: Date) {
        guard config.pauseCharging, helper.status.caps?.charge == true else { chargePaused = false; return }
        // Running from the battery: keep charging paused, or it would resume the instant the adapter returns.
        if level == .battery || applied.adapterOff {
            if !chargePaused { chargePaused = true; chargePausedAt = now }
            return
        }
        guard snap.onAC else { chargePaused = false; return }
        if !chargePaused {
            if snap.batteryW > 1, est > target {
                chargePaused = true
                chargePausedAt = now
                lastChargeW = snap.batteryW * factor
            }
        } else if now.timeIntervalSince(chargePausedAt ?? now) > 30,
                  target - est > min(lastChargeW, 25) + (config.strict ? 4 : 2) {
            chargePaused = false         // real headroom: let it charge again
        }
    }

    private func available(_ l: Lever, snap: PowerSnapshot, config: GovernorConfig) -> Bool {
        let caps = helper.status.caps
        switch l {
        case .dim: return config.dimFloor != nil && hasDisplay
        case .lowPower: return config.lowPowerMode && caps?.lowPower == true
        case .battery:
            return config.batteryBackstop && caps?.adapter == true && (snap.onAC || applied.adapterOff)
                && snap.percent > HelperProtocol.batteryFloor + 5
        }
    }

    private func nextLever(after l: Lever?, snap: PowerSnapshot, config: GovernorConfig) -> Lever? {
        [Lever.dim, .lowPower, .battery].first { (l == nil || $0 > l!) && available($0, snap: snap, config: config) }
    }

    private func previousLever(before l: Lever, snap: PowerSnapshot, config: GovernorConfig) -> Lever? {
        [Lever.battery, .lowPower, .dim].filter { $0 < l }.first { available($0, snap: snap, config: config) }
    }

    private func updateLevel(est: Double, target: Double, deficit: Double, spare: Double, futile: Bool,
                             snap: PowerSnapshot, config: GovernorConfig, now: Date) {
        if let l = level, !available(l, snap: snap, config: config) {
            level = previousLever(before: l, snap: snap, config: config)
        }
        // Measure what the lever bought, for the decision to let go of it later.
        if let l = level, let e0 = estAtEscalation, let t = leverSince, now.timeIntervalSince(t) > 2 {
            leverGain[l] = max(e0 - est, 1)
            estAtEscalation = nil
        }

        // Only when the processes can't carry it: all that can be shed is shed and it is still over.
        let short = deficit > 0.5 && est > config.capW && processesExhausted
        overSince = short ? (overSince ?? now) : nil
        var up = overSince.map { now.timeIntervalSince($0) >= 1.5 } ?? false
        // Strict: a real overshoot the processes can't absorb goes straight to the battery.
        if config.strict, est > config.capW + 1, deficit > 0.5, available(.battery, snap: snap, config: config),
           let o = overSince, now.timeIntervalSince(o) >= 0.6 {
            setLevel(.battery, est: est, now: now); up = false
        }
        // Dimming or Low Power Mode can't make up a futile overshoot; only running from the battery can.
        if up, let next = nextLever(after: level, snap: snap, config: config), !futile || next == .battery {
            setLevel(next, est: est, now: now)
            return
        }

        guard let l = level else { calmSince = nil; return }
        // On battery the estimate already is what the wall would see, so "held without it" is the test.
        let calm = l == .battery ? deficit < 0.5 && est <= target + 0.5
                                 : target - est + spare - (leverGain[l] ?? 0) > 3
        if calm, now.timeIntervalSince(leverSince ?? now) >= l.hold {
            calmSince = calmSince ?? now
            if now.timeIntervalSince(calmSince!) >= (l == .battery ? 5 : 3) {
                level = previousLever(before: l, snap: snap, config: config)
                leverSince = now
                calmSince = nil
            }
        } else {
            calmSince = nil
        }
    }

    private func setLevel(_ l: Lever, est: Double, now: Date) {
        level = l
        leverSince = now
        overSince = nil
        calmSince = nil
        estAtEscalation = est
    }

    private func applyDimming(est: Double, target: Double, config: GovernorConfig) {
        if let l = level, l >= .dim, let floor = config.dimFloor {
            if est > target { dimmer.dim(step: 0.02, floor: floor) }
        } else if dimmer.isDimmed {
            dimmer.restore(step: 0.01)
        }
    }

    private func releaseAll() {
        releaseProcesses()
        engaged = false
        controller.reset()
        level = nil
        chargePaused = false
        overSince = nil; calmSince = nil
        if dimmer.isDimmed { dimmer.restoreAll() }
        // Zero levers, but keep the link: the status stays current and the keepalive is harmless.
        applied = helper.sync(.init())
    }

    private func report(_ state: GovernorState, config: GovernorConfig, est: Double? = nil) -> GovernorReport {
        var r = GovernorReport(state: state, procs: rowsCache)
        r.estW = est
        r.levers.chargePaused = applied.chargeInhibit
        r.levers.lowPower = applied.lowPower
        r.levers.onBattery = applied.adapterOff
        r.levers.dimmedTo = dimmer.isDimmed ? dimmer.current : nil
        r.helper = helper.isInstalled ? helper.status : .notInstalled
        return r
    }
}
