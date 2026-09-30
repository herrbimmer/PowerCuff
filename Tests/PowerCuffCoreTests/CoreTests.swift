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
        XCTAssertEqual(s.wallW, 69.989, accuracy: 0.001)
        XCTAssertEqual(s.adapterRatedW, 140)
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
        XCTAssertEqual(s.wallW, 42, accuracy: 1e-9)
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

    func testGovernorShutdownIsInert() {
        let g = Governor()
        g.shutdown()
        let r = g.tick(snapshot: PowerSnapshot(systemW: 80, wallW: 90, externalConnected: true), capW: 20,
                       enabled: true, frontmostPID: nil, excluded: [])
        XCTAssertEqual(r.state, .off)
    }
}
