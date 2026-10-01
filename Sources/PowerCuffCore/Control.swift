import Foundation

/// Integral + proportional controller that outputs how many watts must be shed. Fast to clamp, slow to let go,
/// like an audio limiter: an overshoot is cut within a tick or two, then released gradually.
public struct ReductionController: Sendable {
    public var kUp: Double
    public var kDown: Double
    public var kp: Double
    public var maxIntegral = 150.0
    /// Seconds of trend extrapolation, damps overshoot from plant lag.
    public var lookahead: Double
    public private(set) var integral = 0.0
    private var last: Double?

    /// For the 5 Hz loop on the IOReport signal (reacts within ~200 ms).
    public static let fast = ReductionController(kUp: 1.2, kDown: 0.15, kp: 0.5, lookahead: 0.3)
    /// For the 1 Hz loop on the SMC rails alone (the plant lags about a second).
    public static let slow = ReductionController(kUp: 0.25, kDown: 0.1, kp: 0.35, lookahead: 1.5)

    public init(kUp: Double = 0.25, kDown: Double = 0.1, kp: Double = 0.35, lookahead: Double = 1.5) {
        self.kUp = kUp; self.kDown = kDown; self.kp = kp; self.lookahead = lookahead
    }

    /// - Parameter freeze: hold the integral (anti-windup) while the target is unreachable.
    public mutating func update(controlledW: Double, targetW: Double, dt: Double, freeze: Bool = false) -> Double {
        let slope = last.map { (controlledW - $0) / max(dt, 0.05) } ?? 0
        last = controlledW
        let err = controlledW + lookahead * max(slope, 0) - targetW
        if !(freeze && err > 0) {
            integral += (err > 0 ? kUp : kDown) * err * dt
            integral = min(max(integral, 0), maxIntegral)
        }
        return integral + kp * max(err, 0)
    }

    public mutating func reset() { integral = 0; last = nil }
}

public struct LoadEntry: Sendable {
    /// Throttle unit: a pid, or a negative process-group id.
    public var pid: pid_t
    /// Estimated watts this unit would draw unthrottled.
    public var watts: Double
    /// Lower tiers are throttled first.
    public var tier: Int
    public init(pid: pid_t, watts: Double, tier: Int) { self.pid = pid; self.watts = watts; self.tier = tier }
}

public enum Allocator {
    /// Spreads a required power reduction over units, tier by tier, proportionally within a tier.
    /// Returns per-unit duty (fraction of time allowed to run, 1 = untouched) and the watts that could not be shed.
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

    /// Watts the units could still shed beyond `reductionW`.
    public static func spareW(reductionW: Double, loads: [LoadEntry], minDuty: Double = 0.08) -> Double {
        max(loads.reduce(0) { $0 + $1.watts } * (1 - minDuty) - max(reductionW, 0), 0)
    }
}

/// Run windows inside the duty-cycle period. Packing the windows end to end (instead of starting every unit at
/// the top of the period) means throttled units take turns, so their peaks don't stack.
public enum Phases {
    /// - Returns: per unit, the start (0..<1, fraction of the period) of a window of length `duty`.
    public static func starts(_ duties: [(id: pid_t, duty: Double)]) -> [pid_t: Double] {
        var at = 0.0
        var out: [pid_t: Double] = [:]
        for d in duties.sorted(by: { $0.id < $1.id }) {
            out[d.id] = at
            at = (at + min(max(d.duty, 0), 1)).truncatingRemainder(dividingBy: 1)
        }
        return out
    }

    /// Running intervals within one period for a window starting at `start` with length `duty` (wraps around).
    public static func intervals(start: Double, duty: Double) -> [(on: Double, off: Double)] {
        let end = start + duty
        return end <= 1 ? [(start, end)] : [(0, end - 1), (start, 1)]
    }
}
