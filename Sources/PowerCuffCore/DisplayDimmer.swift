import Foundation
import CoreGraphics

/// Brightness of the built-in display, 0...1.
public protocol BrightnessBackend: AnyObject {
    func get() -> Double?
    func set(_ v: Double)
}

/// Built-in panel via DisplayServices (private framework, what the brightness keys use; no root).
public final class BuiltInDisplay: BrightnessBackend {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let getFn: Get
    private let setFn: Set

    public init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(h, "DisplayServicesGetBrightness"), let s = dlsym(h, "DisplayServicesSetBrightness")
        else { return nil }
        getFn = unsafeBitCast(g, to: Get.self)
        setFn = unsafeBitCast(s, to: Set.self)
    }

    private var display: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    public func get() -> Double? {
        guard let d = display else { return nil }       // lid closed / no panel
        var v: Float = 0
        return getFn(d, &v) == 0 ? Double(v) : nil
    }

    public func set(_ v: Double) {
        guard let d = display else { return }
        _ = setFn(d, Float(min(max(v, 0), 1)))
    }
}

/// Lowers the backlight in small steps when the cap can't be held otherwise, and brings it back to where the
/// user had it once there is headroom. A change made by someone else (keys, auto-brightness) becomes the new
/// level to return to.
public final class DisplayDimmer {
    private let backend: BrightnessBackend?
    private let defaults: UserDefaults?
    private static let key = "brightnessBeforeDimming"
    /// Brightness to return to; nil while untouched.
    public private(set) var userLevel: Double?
    private var lastSet: Double?

    public var isDimmed: Bool { userLevel != nil }
    public var current: Double? { backend?.get() }

    public init(backend: BrightnessBackend? = BuiltInDisplay(), defaults: UserDefaults? = .standard) {
        self.backend = backend
        self.defaults = defaults
        // A previous run that dimmed and then crashed: put the panel back first.
        if let saved = defaults?.object(forKey: Self.key) as? Double {
            backend?.set(saved)
            defaults?.removeObject(forKey: Self.key)
        }
    }

    private func adoptExternalChange(_ cur: Double) {
        if let l = lastSet, abs(cur - l) > 0.02 {
            userLevel = cur
            lastSet = nil
            persist()
        }
    }

    /// One step down, not below `floor`. Returns false when already at the floor.
    @discardableResult
    public func dim(step: Double, floor: Double) -> Bool {
        guard let backend, let cur = backend.get() else { return false }
        adoptExternalChange(cur)
        guard cur > floor + 0.005 else { return false }
        if userLevel == nil { userLevel = cur; persist() }
        let v = max(floor, cur - step)
        backend.set(v)
        lastSet = v
        return true
    }

    /// One step back towards the user's level. Returns true once fully restored.
    @discardableResult
    public func restore(step: Double) -> Bool {
        guard let backend, userLevel != nil else { return true }
        guard let cur = backend.get() else { return false }
        adoptExternalChange(cur)
        guard let goal = userLevel else { return true }
        let v = min(goal, cur + step)
        if v > cur + 0.001 { backend.set(v); lastSet = v }
        if v >= goal - 0.005 { finish(); return true }
        return false
    }

    /// Straight back to the user's level (quit, sleep, cap off).
    public func restoreAll() {
        if let u = userLevel { backend?.set(u) }
        finish()
    }

    private func finish() {
        userLevel = nil
        lastSet = nil
        persist()
    }

    private func persist() {
        if let u = userLevel { defaults?.set(u, forKey: Self.key) } else { defaults?.removeObject(forKey: Self.key) }
    }
}
