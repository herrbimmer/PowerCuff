import Foundation
import Darwin

/// Hard levers only root can pull (SMC charge/adapter keys, Low Power Mode), held by a small launchd daemon.
/// The app talks to it over a Unix socket with one-line messages. The daemon owns the safety rules: it undoes
/// everything when the app disconnects or goes quiet for `leaseSeconds`, and never runs the Mac from the
/// battery below `batteryFloor` percent.
public enum HelperProtocol {
    public static let version = 1
    public static let label = "com.powercuff.helper"
    public static let socketPath = "/var/run/com.powercuff.helper.sock"
    public static let installedBinary = "/Library/PrivilegedHelperTools/com.powercuff.helper"
    public static let plistPath = "/Library/LaunchDaemons/com.powercuff.helper.plist"
    public static let leaseSeconds = 3.0
    public static let batteryFloor = 15

    public struct Levers: Equatable, Sendable {
        /// Battery stops charging; the Mac still runs from the adapter.
        public var chargeInhibit = false
        /// Adapter input switched off; the Mac runs from the battery and the wall draw drops to ~0.
        public var adapterOff = false
        /// macOS Low Power Mode: lower CPU/GPU clocks.
        public var lowPower = false

        public init(chargeInhibit: Bool = false, adapterOff: Bool = false, lowPower: Bool = false) {
            self.chargeInhibit = chargeInhibit; self.adapterOff = adapterOff; self.lowPower = lowPower
        }
        public var any: Bool { chargeInhibit || adapterOff || lowPower }
    }

    public struct Caps: Equatable, Sendable {
        public var charge = false, adapter = false, lowPower = false
        public init(charge: Bool = false, adapter: Bool = false, lowPower: Bool = false) {
            self.charge = charge; self.adapter = adapter; self.lowPower = lowPower
        }
    }

    private static func bit(_ b: Bool) -> String { b ? "1" : "0" }
    private static func bits(_ parts: ArraySlice<Substring>) -> [Bool]? {
        let v = parts.prefix(3).map { $0 == "1" }
        return parts.count >= 3 && parts.prefix(3).allSatisfy({ $0 == "0" || $0 == "1" }) ? v : nil
    }

    // app -> helper
    public static func hello() -> String { "hello \(version)" }
    public static func encode(set l: Levers) -> String { "set \(bit(l.chargeInhibit)) \(bit(l.adapterOff)) \(bit(l.lowPower))" }
    public static func decodeSet(_ line: String) -> Levers? {
        let p = line.split(separator: " ")
        guard p.first == "set", let b = bits(p.dropFirst()) else { return nil }
        return Levers(chargeInhibit: b[0], adapterOff: b[1], lowPower: b[2])
    }

    // helper -> app
    public static func encode(hello caps: Caps) -> String {
        "ok \(version) \(bit(caps.charge)) \(bit(caps.adapter)) \(bit(caps.lowPower))"
    }
    public static func decodeHello(_ line: String) -> (version: Int, caps: Caps)? {
        let p = line.split(separator: " ")
        guard p.count >= 5, p[0] == "ok", let v = Int(p[1]), let b = bits(p.dropFirst(2)) else { return nil }
        return (v, Caps(charge: b[0], adapter: b[1], lowPower: b[2]))
    }
    /// `note` explains a refusal, e.g. "floor" (battery too low to run from it).
    public static func encode(state l: Levers, note: String? = nil) -> String {
        "state \(bit(l.chargeInhibit)) \(bit(l.adapterOff)) \(bit(l.lowPower))" + (note.map { " \($0)" } ?? "")
    }
    public static func decodeState(_ line: String) -> (levers: Levers, note: String?)? {
        let p = line.split(separator: " ")
        guard p.first == "state", let b = bits(p.dropFirst()) else { return nil }
        return (Levers(chargeInhibit: b[0], adapterOff: b[1], lowPower: b[2]), p.count > 4 ? String(p[4]) : nil)
    }
}

/// `pmset -g custom` output: which Low Power Mode key this Mac uses and its value per power source.
public enum PMSet {
    public static func parsePowerMode(_ text: String) -> (key: String, battery: Int?, ac: Int?)? {
        var section = "", values: [String: [String: Int]] = [:]       // key -> section -> value
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Battery Power") { section = "b"; continue }
            if line.hasPrefix("AC Power") { section = "c"; continue }
            let f = line.split(separator: " ")
            guard f.count >= 2, f[0] == "powermode" || f[0] == "lowpowermode", let v = Int(f[1]) else { continue }
            values[String(f[0]), default: [:]][section] = v
        }
        guard let key = ["powermode", "lowpowermode"].first(where: { values[$0] != nil }) else { return nil }
        return (key, values[key]?["b"], values[key]?["c"])
    }
}

public enum HelperStatus: Equatable, Sendable {
    case notInstalled, unreachable, outdated
    case connected(HelperProtocol.Caps)

    public var caps: HelperProtocol.Caps? { if case .connected(let c) = self { c } else { nil } }
}

/// App side of the helper socket. Blocking I/O with short timeouts; call from one queue.
public final class HelperLink: @unchecked Sendable {
    private let path: String
    private let requireInstall: Bool
    private var fd: Int32 = -1
    private var buffer = Data()
    private var lastAttempt: UInt64 = 0
    public private(set) var status: HelperStatus = .notInstalled
    /// What the helper reports as in effect.
    public private(set) var applied = HelperProtocol.Levers()
    public private(set) var note: String?

    public init(path: String = HelperProtocol.socketPath, requireInstall: Bool = true) {
        self.path = path
        self.requireInstall = requireInstall
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    public var isInstalled: Bool { !requireInstall || FileManager.default.fileExists(atPath: HelperProtocol.plistPath) }

    /// Sends the wanted state (doubles as the keepalive) and returns what the helper applied.
    @discardableResult
    public func sync(_ want: HelperProtocol.Levers) -> HelperProtocol.Levers {
        guard connect() else { applied = .init(); return applied }
        guard let reply = exchange(HelperProtocol.encode(set: want)), let s = HelperProtocol.decodeState(reply) else {
            disconnect(); applied = .init(); return applied
        }
        applied = s.levers
        note = s.note
        return applied
    }

    /// Drops every lever and disconnects (the helper also reverts on disconnect).
    public func release() {
        if fd >= 0 { _ = exchange(HelperProtocol.encode(set: .init())) }
        disconnect()
        applied = .init()
    }

    /// Re-checks install state without waiting for the retry backoff.
    public func refresh() {
        lastAttempt = 0
        if fd < 0 { _ = connect() }
    }

    private func connect() -> Bool {
        if fd >= 0 { return true }
        guard isInstalled else { status = .notInstalled; return false }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard now &- lastAttempt > 3_000_000_000 || lastAttempt == 0 else { return false }
        lastAttempt = now
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { status = .unreachable; return false }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let b = Array(path.utf8.prefix(dst.count - 1))
            dst.copyBytes(from: b)
            dst[b.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { Darwin.close(s); status = .unreachable; return false }
        fd = s
        buffer = Data()
        guard let reply = exchange(HelperProtocol.hello()), let h = HelperProtocol.decodeHello(reply) else {
            disconnect(); status = .unreachable; return false
        }
        guard h.version == HelperProtocol.version else { disconnect(); status = .outdated; return false }
        status = .connected(h.caps)
        return true
    }

    private func disconnect() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        if case .connected = status { status = .unreachable }
    }

    private func exchange(_ line: String) -> String? {
        let out = Array((line + "\n").utf8)
        guard out.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == out.count else { return nil }
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let l = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return l
            }
            var chunk = [UInt8](repeating: 0, count: 256)
            let n = Darwin.read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk.prefix(n))
        }
    }
}
