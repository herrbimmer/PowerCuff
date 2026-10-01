import XCTest
@testable import PowerCuffCore

final class CoreTests: XCTestCase {
    func testParseAC() {
        let p: [String: Any] = [
            "ExternalConnected": true, "IsCharging": false, "CurrentCapacity": 80, "Voltage": 12088,
            "InstantAmperage": 0, "TimeRemaining": 65535, "Temperature": 3070, "CycleCount": 306,
            "AdapterDetails": ["Watts": 140, "Name": "140W USB-C Power Adapter", "AdapterVoltage": 28000],
            "PowerTelemetryData": ["SystemLoad": 68262, "SystemPowerIn": 68262, "AdapterEfficiencyLoss": 1727],
        ]
        let s = PowerSnapshot.parse(p)
        XCTAssertEqual(s.systemW, 68.262, accuracy: 0.001)
        XCTAssertEqual(s.dcInW, 68.262, accuracy: 0.001)
        // Load-dependent brick efficiency + cable loss (~75 W), above Apple's own 70 W estimate.
        XCTAssertGreaterThan(s.wallW, 73)
        XCTAssertLessThan(s.wallW, 78)
        XCTAssertEqual(s.adapterRatedW, 140)
        XCTAssertEqual(s.adapterSpareW ?? 0, 140 - 68.262, accuracy: 0.001)
        XCTAssertEqual(s.adapterVolts, 28)
        XCTAssertNil(s.minutesRemaining)
        XCTAssertEqual(s.temperatureC ?? 0, 30.7, accuracy: 0.01)
        XCTAssertEqual(s.controlledW, s.wallW)
    }

    func testSMCOverridesTelemetry() {
        let p: [String: Any] = ["ExternalConnected": true, "PowerTelemetryData": ["SystemLoad": 68262]]
        let s = PowerSnapshot.parse(p, smc: SMCReading(systemW: 30, dcInW: 40))
        XCTAssertEqual(s.systemW, 30)
        XCTAssertEqual(s.batteryW, 10, accuracy: 1e-9)
        XCTAssertEqual(s.dcInW, 40)
        XCTAssertEqual(s.wallW, 44, accuracy: 0.5)          // the old fixed 1.05 factor said 42
        XCTAssertGreaterThan(s.wallW, 40 * 1.05)
    }

    func testPeakComesFromTheWindow() {
        let p: [String: Any] = ["ExternalConnected": true]
        let s = PowerSnapshot.parse(p, smc: SMCReading(systemW: 30, dcInW: 40, peakSystemW: 55, peakDcInW: 60))
        XCTAssertGreaterThan(s.peakW, s.wallW + 15)
        XCTAssertEqual(s.peakW, AdapterLoss.wallW(dcW: 60, ratedW: nil, volts: nil), accuracy: 1e-9)
    }

    func testFixedEfficiencyCalibration() {
        XCTAssertEqual(AdapterLoss.wallW(dcW: 50, ratedW: 96, volts: 20, fixedEfficiency: 0.9), 50 / 0.9, accuracy: 1e-9)
        XCTAssertEqual(AdapterLoss.wallW(dcW: 0, ratedW: 96, volts: 20), 0)
        // Light load is less efficient than full load.
        XCTAssertLessThan(AdapterLoss.efficiency(loadFraction: 0.1), AdapterLoss.efficiency(loadFraction: 0.9))
    }

    func testNegativeSystemLoadReadsAsMagnitude() {
        // Unsigned view of -20335 mW, as IOKit hands it over while discharging.
        let p: [String: Any] = ["ExternalConnected": false,
                                "PowerTelemetryData": ["SystemLoad": NSNumber(value: UInt64(18446744073709531281))]]
        XCTAssertEqual(PowerSnapshot.parse(p).systemW, 20.335, accuracy: 0.001)
    }

    func testLiveSMCRead() throws {
        guard let r = SMCReader.shared.read() else { throw XCTSkip("no SMC") }
        XCTAssertGreaterThan(r.systemW, 0)
        XCTAssertLessThan(r.systemW, 400)
    }

    func testParseDischargeNegativeAmperage() {
        let p: [String: Any] = [
            "ExternalConnected": false, "Voltage": 12000, "InstantAmperage": NSNumber(value: Int64(-2000)),
            "TimeRemaining": 90, "PowerTelemetryData": ["SystemLoad": 24000],
        ]
        let s = PowerSnapshot.parse(p)
        XCTAssertEqual(s.batteryW, -24, accuracy: 0.001)
        XCTAssertEqual(s.wallW, 0)
        XCTAssertEqual(s.controlledW, 24, accuracy: 0.001)
        XCTAssertEqual(s.minutesRemaining, 90)
    }

    func testAllocatorTiers() {
        let loads = [LoadEntry(pid: 1, watts: 20, tier: 0), LoadEntry(pid: 2, watts: 20, tier: 0),
                     LoadEntry(pid: 3, watts: 30, tier: 1)]
        var r = Allocator.duties(reductionW: 20, loads: loads)
        XCTAssertEqual(r.duties[1] ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.duties[3], 1)
        XCTAssertEqual(r.unmetW, 0, accuracy: 1e-9)
        r = Allocator.duties(reductionW: 60, loads: loads)
        XCTAssertEqual(r.duties[1] ?? 0, 0.08, accuracy: 1e-9)
        XCTAssertLessThan(r.duties[3] ?? 1, 1)
        r = Allocator.duties(reductionW: 500, loads: loads)
        XCTAssertGreaterThan(r.unmetW, 0)
    }

    /// Fake plant: floor + demand*duty with a one-pole lag, run through controller + allocator.
    func testControllerConverges() {
        var c = ReductionController()
        let floor = 10.0, demand = 80.0, target = 40.0
        var duty = 1.0, power = floor + demand
        var lastUnmet = 0.0
        var tail: [Double] = []
        for t in 0..<90 {
            let r = c.update(controlledW: power, targetW: target, dt: 1, freeze: lastUnmet > 0.5)
            let res = Allocator.duties(reductionW: r, loads: [LoadEntry(pid: 1, watts: demand * duty / max(duty, 0.08) , tier: 0)])
            lastUnmet = res.unmetW
            duty = res.duties[1] ?? 1
            power += 0.5 * ((floor + demand * duty) - power)
            if t > 45 { tail.append(power) }
        }
        XCTAssertLessThan(abs(tail.last! - target), 1.5)
        XCTAssertLessThan(tail.max()! - target, 4)
    }

    func testControllerUnreachableDoesNotWindUp() {
        var c = ReductionController()
        for _ in 0..<100 { _ = c.update(controlledW: 50, targetW: 5, dt: 1, freeze: true) }
        XCTAssertEqual(c.integral, 0, accuracy: 1e-9)
    }

    private func stat(_ pid: pid_t) -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "stat=", "-p", String(pid)]
        p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Quitting must release everything and a late governor tick must not re-freeze anything.
    func testReleaseAllResumesAndRefusesFurtherThrottling() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let pid = sleeper.processIdentifier

        let engine = ThrottleEngine()
        engine.apply(duties: [pid: 0.2])
        Thread.sleep(forTimeInterval: 0.6)
        engine.releaseAll()
        XCTAssertFalse(stat(pid).hasPrefix("T"), "still stopped after releaseAll")

        engine.apply(duties: [pid: 0.2])          // a tick that was in flight when the app quit
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(stat(pid).hasPrefix("T"), "throttled again after shutdown")
        XCTAssertEqual(engine.throttledCount, 0)
    }

    private func inertGovernor() -> Governor {
        Governor(meter: nil, dimmer: DisplayDimmer(backend: nil, defaults: nil),
                 helper: HelperLink(path: "/nonexistent/powercuff.sock", requireInstall: false))
    }

    func testGovernorShutdownIsInert() {
        let g = inertGovernor()
        g.shutdown()
        var cfg = GovernorConfig(); cfg.capW = 20; cfg.enabled = true
        let r = g.tick(snapshot: PowerSnapshot(systemW: 80, wallW: 90, externalConnected: true), config: cfg, frontmostPID: nil)
        XCTAssertEqual(r.state, .off)
    }

    func testGovernorOffDoesNothing() {
        let g = inertGovernor()
        var cfg = GovernorConfig(); cfg.enabled = false
        let r = g.tick(snapshot: PowerSnapshot(systemW: 80, wallW: 90, externalConnected: true), config: cfg, frontmostPID: nil)
        XCTAssertEqual(r.state, .off)
        XCTAssertEqual(r.levers, LeverState())
    }

    // MARK: new pieces

    func testFastControllerReactsFasterThanSlow() {
        func settle(_ c: ReductionController, dt: Double) -> Int {
            var c = c
            var power = 90.0, duty = 1.0
            for step in 0..<400 {
                let r = c.update(controlledW: power, targetW: 40, dt: dt)
                duty = Allocator.duties(reductionW: r, loads: [LoadEntry(pid: 1, watts: 80, tier: 0)]).duties[1] ?? 1
                power += min(1, dt / 0.5) * ((10 + 80 * duty) - power)       // same plant lag for both
                if power < 41 { return step }
            }
            return 400
        }
        let fast = Double(settle(.fast, dt: 0.2)) * 0.2
        let slow = Double(settle(.slow, dt: 1.0)) * 1.0
        XCTAssertLessThan(fast, slow)
        XCTAssertLessThan(fast, slow / 2, "fast \(fast) s vs slow \(slow) s")
        XCTAssertLessThan(fast, 4)
    }

    func testControllerReleasesSlowly() {
        var c = ReductionController.fast
        for _ in 0..<20 { _ = c.update(controlledW: 80, targetW: 40, dt: 0.2) }
        let held = c.integral
        _ = c.update(controlledW: 30, targetW: 40, dt: 0.2)
        XCTAssertGreaterThan(c.integral, held * 0.8)       // one calm tick doesn't drop the clamp
    }

    func testIntegralIsLimitedToWhatCanBeShed() {
        var c = ReductionController.fast
        for _ in 0..<200 { _ = c.update(controlledW: 100, targetW: 40, dt: 0.2, limit: 20) }
        XCTAssertLessThanOrEqual(c.integral, 20 + 1e-9, "wound up past the sheddable load")
        // Overshoot ends: it unwinds from 20 W, not from the 150 W it would otherwise have reached.
        var ticks = 0
        while c.update(controlledW: 30, targetW: 40, dt: 0.2, limit: 20) > 1, ticks < 400 { ticks += 1 }
        XCTAssertLessThan(Double(ticks) * 0.2, 15)
    }

    func testAllocatorSpare() {
        let loads = [LoadEntry(pid: 1, watts: 20, tier: 0), LoadEntry(pid: 2, watts: 30, tier: 1)]
        XCTAssertEqual(Allocator.spareW(reductionW: 10, loads: loads), 50 * 0.92 - 10, accuracy: 1e-9)
        XCTAssertEqual(Allocator.spareW(reductionW: 500, loads: loads), 0)
    }

    func testPhasesDoNotStartTogether() {
        let starts = Phases.starts([(1, 0.3), (2, 0.3), (3, 0.3)])
        XCTAssertEqual(starts[1], 0)
        XCTAssertEqual(starts[2] ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(starts[3] ?? 0, 0.6, accuracy: 1e-9)
        // Three 30 % windows packed end to end never overlap: at most one unit runs at a time.
        for t in stride(from: 0.0, to: 1.0, by: 0.01) {
            let running = starts.filter { (id, st) in
                Phases.intervals(start: st, duty: 0.3).contains { t >= $0.on && t < $0.off }
            }.count
            XCTAssertLessThanOrEqual(running, 1, "overlap at \(t)")
        }
    }

    func testPhaseWrapAround() {
        let spans = Phases.intervals(start: 0.8, duty: 0.4)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].on, 0); XCTAssertEqual(spans[0].off, 0.2, accuracy: 1e-9)
        XCTAssertEqual(spans[1].on, 0.8, accuracy: 1e-9); XCTAssertEqual(spans[1].off, 1)
    }

    func testHelperProtocolRoundTrip() {
        let l = HelperProtocol.Levers(chargeInhibit: true, adapterOff: false, lowPower: true)
        XCTAssertEqual(HelperProtocol.decodeSet(HelperProtocol.encode(set: l)), l)
        XCTAssertNil(HelperProtocol.decodeSet("set 1 2 0"))
        XCTAssertNil(HelperProtocol.decodeSet("explode 1 1 1"))
        let caps = HelperProtocol.Caps(charge: true, adapter: false, lowPower: true)
        let h = HelperProtocol.decodeHello(HelperProtocol.encode(hello: caps))
        XCTAssertEqual(h?.caps, caps)
        XCTAssertEqual(h?.version, HelperProtocol.version)
        let st = HelperProtocol.decodeState(HelperProtocol.encode(state: l, note: "floor"))
        XCTAssertEqual(st?.levers, l)
        XCTAssertEqual(st?.note, "floor")
    }

    func testPMSetParsing() {
        let hpm = """
        Battery Power:
         powermode            0
         sleep                1
        AC Power:
         powermode            2
        """
        let a = PMSet.parsePowerMode(hpm)
        XCTAssertEqual(a?.key, "powermode"); XCTAssertEqual(a?.battery, 0); XCTAssertEqual(a?.ac, 2)
        let lpm = "Battery Power:\n lowpowermode 1\nAC Power:\n lowpowermode 0\n"
        let b = PMSet.parsePowerMode(lpm)
        XCTAssertEqual(b?.key, "lowpowermode"); XCTAssertEqual(b?.battery, 1); XCTAssertEqual(b?.ac, 0)
        XCTAssertNil(PMSet.parsePowerMode("Battery Power:\n sleep 1\n"))
    }

    // MARK: display dimmer

    private final class FakePanel: BrightnessBackend {
        var level: Double?
        init(_ l: Double?) { level = l }
        func get() -> Double? { level }
        func set(_ v: Double) { level = v }
    }

    func testDimmerDimsToFloorAndRestores() {
        let panel = FakePanel(0.8)
        let d = DisplayDimmer(backend: panel, defaults: nil)
        XCTAssertTrue(d.dim(step: 0.1, floor: 0.5))
        XCTAssertEqual(panel.level ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertTrue(d.isDimmed)
        for _ in 0..<10 { d.dim(step: 0.1, floor: 0.5) }
        XCTAssertEqual(panel.level ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertFalse(d.dim(step: 0.1, floor: 0.5), "at the floor")
        for _ in 0..<10 { d.restore(step: 0.1) }
        XCTAssertEqual(panel.level ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertFalse(d.isDimmed)
    }

    func testDimmerAdoptsManualChange() {
        let panel = FakePanel(0.8)
        let d = DisplayDimmer(backend: panel, defaults: nil)
        d.dim(step: 0.1, floor: 0.3)
        panel.level = 0.9                                   // user turned it up
        d.dim(step: 0.1, floor: 0.3)
        XCTAssertEqual(d.userLevel ?? 0, 0.9, accuracy: 1e-9)
        d.restoreAll()
        XCTAssertEqual(panel.level ?? 0, 0.9, accuracy: 1e-9)
    }

    func testDimmerWithoutPanelDoesNothing() {
        let d = DisplayDimmer(backend: FakePanel(nil), defaults: nil)
        XCTAssertFalse(d.dim(step: 0.1, floor: 0.2))
        XCTAssertFalse(d.isDimmed)
    }

    func testDimmerRestoresAfterCrash() {
        let suite = UserDefaults(suiteName: "powercuff.test.\(UUID().uuidString)")!
        let panel = FakePanel(0.8)
        let first = DisplayDimmer(backend: panel, defaults: suite)
        first.dim(step: 0.3, floor: 0.2)                    // "crash": never restored
        XCTAssertEqual(panel.level ?? 0, 0.5, accuracy: 1e-9)
        _ = DisplayDimmer(backend: panel, defaults: suite)  // next launch
        XCTAssertEqual(panel.level ?? 0, 0.8, accuracy: 1e-9)
    }

    // MARK: helper (dry run: never touches the real SMC or pmset)

    private func helperBinary() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for dir in [".build/debug", ".build/release", ".build/arm64-apple-macosx/debug"] {
            let u = root.appendingPathComponent(dir).appendingPathComponent("PowerCuffHelper")
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        throw XCTSkip("PowerCuffHelper not built")
    }

    private func startHelper(_ dir: String) throws -> Process {
        let p = Process()
        p.executableURL = try helperBinary()
        p.arguments = ["--socket", dir + "/h.sock", "--state", dir + "/state.json", "--dry-run", "--any-client"]
        p.standardError = FileHandle.nullDevice
        try p.run()
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: dir + "/h.sock") { Thread.sleep(forTimeInterval: 0.05) }
        return p
    }

    func testHelperLeaseAndDisconnectRelease() throws {
        let dir = NSTemporaryDirectory() + "pc-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let h = try startHelper(dir)
        defer { h.terminate(); try? FileManager.default.removeItem(atPath: dir) }

        let link = HelperLink(path: dir + "/h.sock", requireInstall: false)
        let before = link.sync(.init())
        XCTAssertFalse(before.any)
        guard let caps = link.status.caps else { return XCTFail("not connected: \(link.status)") }

        let applied = link.sync(.init(chargeInhibit: true, adapterOff: false, lowPower: false))
        XCTAssertEqual(applied.chargeInhibit, caps.charge)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/state.json") == caps.charge)

        // Silence past the lease: the helper lets go on its own.
        Thread.sleep(forTimeInterval: HelperProtocol.leaseSeconds + 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/state.json"), "lease expiry did not release")
        let after = link.sync(.init(chargeInhibit: true))
        XCTAssertEqual(after.chargeInhibit, caps.charge)

        // Disconnecting releases and clears the persisted state.
        link.release()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/state.json"))
        let again = HelperLink(path: dir + "/h.sock", requireInstall: false)
        XCTAssertFalse(again.sync(.init()).any)
    }

    func testHelperRecoversStateAfterCrash() throws {
        let dir = NSTemporaryDirectory() + "pc-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // A previous run died holding the adapter off.
        try Data(#"{"charge":true,"adapter":true}"#.utf8).write(to: URL(fileURLWithPath: dir + "/state.json"))
        let h = try startHelper(dir)
        defer { h.terminate() }
        for _ in 0..<40 where FileManager.default.fileExists(atPath: dir + "/state.json") { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/state.json"), "stale state not undone at start")
    }

    func testLinkToMissingHelperIsHarmless() {
        let link = HelperLink(path: "/nonexistent/x.sock", requireInstall: false)
        XCTAssertFalse(link.sync(.init(chargeInhibit: true)).any)
        XCTAssertEqual(link.status, .unreachable)
    }
}
