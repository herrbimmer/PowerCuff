import Foundation

/// Integral + proportional controller that outputs how many watts must be shed.
public struct ReductionController: Sendable {
    public var kUp = 0.25
    public var kDown = 0.1
    public var kp = 0.35
    public var maxIntegral = 150.0
    /// Seconds of trend extrapolation, damps overshoot from plant lag.
    public var lookahead = 1.5
    public private(set) var integral = 0.0
    private var last: Double?

    public init() {}

    /// - Parameter freeze: hold the integral (anti-windup) while the target is unreachable.
    public mutating func update(controlledW: Double, targetW: Double, dt: Double, freeze: Bool = false) -> Double {
        let slope = last.map { (controlledW - $0) / max(dt, 0.1) } ?? 0
        last = controlledW
        let err = controlledW + lookahead * slope - targetW
        if !(freeze && err > 0) {
            integral += (err > 0 ? kUp : kDown) * err * dt
            integral = min(max(integral, 0), maxIntegral)
        }
        return integral + kp * max(err, 0)
    }

    public mutating func reset() { integral = 0; last = nil }
}

public struct LoadEntry: Sendable {
    public var pid: pid_t
    /// Estimated watts this process would draw unthrottled.
    public var watts: Double
    /// Lower tiers are throttled first.
    public var tier: Int
    public init(pid: pid_t, watts: Double, tier: Int) { self.pid = pid; self.watts = watts; self.tier = tier }
}

public enum Allocator {
    /// Spreads a required power reduction over processes, tier by tier, proportionally within a tier.
    /// Returns per-pid duty (fraction of time allowed to run, 1 = untouched) and the watts that could not be shed.
    public static func duties(reductionW: Double, loads: [LoadEntry], minDuty: Double = 0.08)
        -> (duties: [pid_t: Double], unmetW: Double) {
        var remaining = max(0, reductionW)
        var out: [pid_t: Double] = [:]
        for tier in Set(loads.map(\.tier)).sorted() {
            let group = loads.filter { $0.tier == tier }
            let total = group.reduce(0) { $0 + $1.watts }
            guard total > 0 else { group.forEach { out[$0.pid] = 1 }; continue }
            let cut = min(remaining, total * (1 - minDuty))
            let frac = cut / total
            group.forEach { out[$0.pid] = 1 - frac }
            remaining -= cut
        }
        return (out, remaining)
    }
}
