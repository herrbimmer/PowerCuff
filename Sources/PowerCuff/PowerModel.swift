import SwiftUI
import AppKit
import ServiceManagement
import PowerCuffCore

struct HistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let watts: Double
}

/// How often the shown wattage refreshes. The SMC publishes a new reading about once a second, so
/// faster rates only cut latency; slower rates show the mean over the interval.
enum RefreshRate {
    static let options: [Double] = [0.5, 1, 2, 5, 10]
    static let standard = 1.0

    static func label(_ s: Double) -> String { s < 1 ? String(format: "%.1f s", s) : "\(Int(s)) s" }
    /// Animation that finishes just before the next update so motion never stalls or overlaps.
    static func animation(_ s: Double) -> Animation { .smooth(duration: min(max(s * 0.9, 0.25), 0.8)) }
}

@MainActor @Observable
final class PowerModel {
    static let shared = PowerModel()

    private(set) var snapshot: PowerSnapshot?
    private(set) var report = GovernorReport()
    private(set) var history: [HistoryPoint] = []
    private(set) var capW: Double
    private(set) var enabled: Bool
    private(set) var excluded: Set<String>
    private(set) var showInDock: Bool
    private(set) var launchAtLogin: Bool
    private(set) var refreshSeconds: Double
    private(set) var strict: Bool
    /// Lowest brightness the governor may dim to; 0 = never dim.
    private(set) var dimFloor: Double
    private(set) var pauseCharging: Bool
    private(set) var lowPowerMode: Bool
    private(set) var batteryBackstop: Bool
    /// Fixed adapter efficiency for the wall estimate; 0 = automatic (conservative model).
    private(set) var efficiency: Double
    private(set) var helperBusy = false

    @ObservationIgnored private let governor = Governor()
    /// Governor work (process sampling, signals) never blocks the display reads.
    @ObservationIgnored private let controlQueue = DispatchQueue(label: "app.powercuff.governor", qos: .userInitiated)
    @ObservationIgnored private let displayQueue = DispatchQueue(label: "app.powercuff.display", qos: .userInitiated)
    @ObservationIgnored private var controlTimer: DispatchSourceTimer?
    @ObservationIgnored private var controlPeriod = 0.0
    @ObservationIgnored private let shared = SharedConfig()
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var displayTimer: Timer?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var isSleeping = false
    @ObservationIgnored private let defaults = UserDefaults.standard

    static let capRange: ClosedRange<Double> = 15...150
    private static let historySpan: TimeInterval = 120

    private init() {
        let d = UserDefaults.standard
        capW = d.object(forKey: "capW") as? Double ?? 60
        enabled = d.object(forKey: "enabled") as? Bool ?? false
        excluded = Set(d.stringArray(forKey: "excluded") ?? [])
        showInDock = d.bool(forKey: "showInDock")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let r = d.object(forKey: "refreshSeconds") as? Double ?? RefreshRate.standard
        refreshSeconds = RefreshRate.options.contains(r) ? r : RefreshRate.standard
        strict = d.bool(forKey: "strict")
        dimFloor = d.object(forKey: "dimFloor") as? Double ?? 0.4
        pauseCharging = d.object(forKey: "pauseCharging") as? Bool ?? true
        lowPowerMode = d.object(forKey: "lowPowerMode") as? Bool ?? true
        batteryBackstop = d.object(forKey: "batteryBackstop") as? Bool ?? true
        efficiency = d.double(forKey: "efficiency")
        start()
    }

    var config: GovernorConfig {
        var c = GovernorConfig()
        c.capW = capW; c.enabled = enabled; c.strict = strict; c.excluded = excluded
        c.dimFloor = dimFloor > 0 ? dimFloor : nil
        c.pauseCharging = pauseCharging; c.lowPowerMode = lowPowerMode; c.batteryBackstop = batteryBackstop
        c.efficiency = efficiency > 0 ? efficiency : nil
        return c
    }

    /// Settings the control queue reads without hopping to the main actor.
    private func pushConfig() { shared.set(config) }

    // MARK: intents

    /// Live while dragging; the value is persisted shortly after the last change.
    func setCap(_ w: Double) {
        let v = min(max(w.rounded(), Self.capRange.lowerBound), Self.capRange.upperBound)
        guard v != capW else { return }
        capW = v
        pushConfig()
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.defaults.set(self.capW, forKey: "capW")
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: "enabled")
        pushConfig()
        controlQueue.async { [self] in controlTick() }
    }

    func setStrict(_ on: Bool) { strict = on; defaults.set(on, forKey: "strict"); pushConfig() }
    func setDimFloor(_ v: Double) { dimFloor = v; defaults.set(v, forKey: "dimFloor"); pushConfig() }
    func setPauseCharging(_ on: Bool) { pauseCharging = on; defaults.set(on, forKey: "pauseCharging"); pushConfig() }
    func setLowPowerMode(_ on: Bool) { lowPowerMode = on; defaults.set(on, forKey: "lowPowerMode"); pushConfig() }
    func setBatteryBackstop(_ on: Bool) { batteryBackstop = on; defaults.set(on, forKey: "batteryBackstop"); pushConfig() }

    func setEfficiency(_ v: Double) {
        efficiency = v
        defaults.set(v, forKey: "efficiency")
        pushConfig()
        displayTick()
    }

    func setRefresh(_ seconds: Double) {
        refreshSeconds = seconds
        defaults.set(seconds, forKey: "refreshSeconds")
        startDisplayTimer()
    }

    func toggleExcluded(_ name: String) {
        if excluded.contains(name) { excluded.remove(name) } else { excluded.insert(name) }
        defaults.set(Array(excluded), forKey: "excluded")
        pushConfig()
    }

    // MARK: helper

    var helperInstalled: Bool { report.helper != .notInstalled }

    /// Installs (or updates) the root helper for the hard levers. macOS asks for an administrator password.
    func installHelper() { runHelperScript(HelperInstaller.installScript(helper: HelperInstaller.bundledHelperPath)) }
    func uninstallHelper() { runHelperScript(HelperInstaller.uninstallScript) }

    private func runHelperScript(_ script: String?) {
        guard let script, !helperBusy else { return }
        helperBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = HelperInstaller.runAsAdmin(script)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.helperBusy = false
                    if !ok { NSLog("PowerCuff: helper script cancelled or failed") }
                }
            }
        }
    }

    func setShowInDock(_ on: Bool) {
        showInDock = on
        defaults.set(on, forKey: "showInDock")
        NSApp.setActivationPolicy(on ? .regular : .accessory)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("PowerCuff: launch-at-login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Stops all timers and gives every throttled process back its normal state. Idempotent; after this
    /// the governor can no longer throttle anything.
    func shutdown() {
        isShutDown = true
        controlTimer?.cancel(); controlTimer = nil
        displayTimer?.invalidate(); displayTimer = nil
        persistTask?.cancel()
        defaults.set(capW, forKey: "capW")
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        shared.kill()
        governor.shutdown()
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    // MARK: loops

    private func start() {
        let nc = NSWorkspace.shared.notificationCenter
        pushConfig()
        shared.setFront(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        observers = [
            nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.shared.setFront(app?.processIdentifier) }
            },
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            },
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            },
            nc.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.shutdown() }
            },
        ]
        resume()
    }

    /// Before sleep nothing may stay frozen.
    private func pause() {
        isSleeping = true
        controlTimer?.cancel(); controlTimer = nil
        displayTimer?.invalidate(); displayTimer = nil
        controlQueue.async { [governor] in governor.releaseThrottles() }
    }

    private func resume() {
        guard !isShutDown else { return }
        isSleeping = false
        controlTimer?.cancel()
        controlTimer = nil
        controlQueue.async { [self] in controlTick() }
        startDisplayTimer()
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
        guard !isShutDown, !isSleeping else { return }
        let t = Timer(timeInterval: refreshSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayTick() }
        }
        t.tolerance = refreshSeconds * 0.05
        RunLoop.main.add(t, forMode: .common)
        displayTimer = t
        displayTick()
    }

    /// Runs on `controlQueue`: 5 Hz while enforcing (the controller is tuned for it), 1 Hz when only monitoring,
    /// whatever rate is shown.
    private nonisolated func controlTick() {
        let (cfg, front, live) = shared.get()
        guard live else { return }
        let snap = BatteryReader.read(efficiency: cfg.efficiency)
        let rep = governor.tick(snapshot: snap, config: cfg, frontmostPID: front)
        let period = governor.interval(enabled: cfg.enabled)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.publish(report: rep)
                self.scheduleControl(period)
            }
        }
    }

    private func scheduleControl(_ period: Double) {
        guard !isShutDown, !isSleeping, period != controlPeriod || controlTimer == nil else { return }
        controlTimer?.cancel()
        controlPeriod = period
        let t = DispatchSource.makeTimerSource(queue: controlQueue)
        t.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(Int(period * 50)))
        t.setEventHandler { [weak self] in self?.controlTick() }
        t.resume()
        controlTimer = t
    }

    private func displayTick() {
        guard !isShutDown, !isSleeping else { return }
        let window = min(refreshSeconds, SMCReader.maxWindow)
        let eff = efficiency > 0 ? efficiency : nil
        displayQueue.async {
            let snap = BatteryReader.read(window: window, efficiency: eff)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.publish(snapshot: snap) }
            }
        }
    }

    /// The fast estimate changes every tick; the UI only needs it about once a second.
    private func publish(report rep: GovernorReport) {
        guard !isShutDown, report != rep else { return }
        let structural = rep.state != report.state || rep.levers != report.levers || rep.helper != report.helper
            || rep.procs != report.procs
        guard structural || Date().timeIntervalSince(lastPublish) >= 1 else { return }
        report = rep
        lastPublish = Date()
    }

    private func publish(snapshot snap: PowerSnapshot?) {
        guard !isShutDown else { return }
        snapshot = snap
        guard let s = snap else { return }
        // History runs at most 1 point/s so the 2-minute chart looks the same at any refresh rate.
        if let last = history.last, s.date.timeIntervalSince(last.date) < 0.9 { return }
        history.append(HistoryPoint(date: s.date, watts: s.controlledW))
        let cutoff = s.date.addingTimeInterval(-Self.historySpan)
        if let first = history.first, first.date < cutoff { history.removeAll { $0.date < cutoff } }
    }
}
