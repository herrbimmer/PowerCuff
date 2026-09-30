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

    @ObservationIgnored private let governor = Governor()
    /// Governor work (process sampling, signals) never blocks the display reads.
    @ObservationIgnored private let controlQueue = DispatchQueue(label: "app.powercuff.governor", qos: .userInitiated)
    @ObservationIgnored private let displayQueue = DispatchQueue(label: "app.powercuff.display", qos: .userInitiated)
    @ObservationIgnored private var controlTimer: Timer?
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
        start()
    }

    // MARK: intents

    /// Live while dragging; the value is persisted shortly after the last change.
    func setCap(_ w: Double) {
        let v = min(max(w.rounded(), Self.capRange.lowerBound), Self.capRange.upperBound)
        guard v != capW else { return }
        capW = v
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
        controlTick()
    }

    func setRefresh(_ seconds: Double) {
        refreshSeconds = seconds
        defaults.set(seconds, forKey: "refreshSeconds")
        startDisplayTimer()
    }

    func toggleExcluded(_ name: String) {
        if excluded.contains(name) { excluded.remove(name) } else { excluded.insert(name) }
        defaults.set(Array(excluded), forKey: "excluded")
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
        controlTimer?.invalidate(); controlTimer = nil
        displayTimer?.invalidate(); displayTimer = nil
        persistTask?.cancel()
        defaults.set(capW, forKey: "capW")
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        governor.shutdown()
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    // MARK: loops

    private func start() {
        let nc = NSWorkspace.shared.notificationCenter
        observers = [
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
        controlTimer?.invalidate(); controlTimer = nil
        displayTimer?.invalidate(); displayTimer = nil
        controlQueue.async { [governor] in governor.releaseThrottles() }
    }

    private func resume() {
        guard !isShutDown else { return }
        isSleeping = false
        controlTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.controlTick() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        controlTimer = t
        controlTick()
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

    /// Fixed 1 Hz: the controller is tuned for it, whatever rate is shown.
    private func controlTick() {
        guard !isShutDown, !isSleeping else { return }
        let cap = capW, on = enabled, ex = excluded
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        controlQueue.async { [governor] in
            let snap = BatteryReader.read()
            let rep = governor.tick(snapshot: snap, capW: cap, enabled: on, frontmostPID: front, excluded: ex)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.publish(report: rep) }
            }
        }
    }

    private func displayTick() {
        guard !isShutDown, !isSleeping else { return }
        let window = min(refreshSeconds, SMCReader.maxWindow)
        displayQueue.async {
            let snap = BatteryReader.read(window: window)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.publish(snapshot: snap) }
            }
        }
    }

    private func publish(report rep: GovernorReport) {
        guard !isShutDown else { return }
        if report != rep { report = rep }
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
