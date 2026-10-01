import Foundation
import Darwin
import PowerCuffCore

// PowerCuff privileged helper (launchd daemon, root). Usage for testing without root:
//   PowerCuffHelper --socket /tmp/x.sock --state /tmp/x.json --dry-run --any-client
var socketPath = HelperProtocol.socketPath
var statePath = "/Library/Application Support/PowerCuff/helper-state.json"
var dryRun = false, anyClient = false
var argv = CommandLine.arguments.dropFirst().makeIterator()
while let a = argv.next() {
    switch a {
    case "--socket": socketPath = argv.next() ?? socketPath
    case "--state": statePath = argv.next() ?? statePath
    case "--dry-run": dryRun = true
    case "--any-client": anyClient = true
    default: log("unknown argument \(a)"); exit(64)
    }
}

nonisolated(unsafe) var quitRequested: sig_atomic_t = 0
for s in [SIGTERM, SIGINT, SIGHUP] { signal(s) { _ in quitRequested = 1 } }
signal(SIGPIPE, SIG_IGN)

let levers = HardLevers(dryRun: dryRun, statePath: statePath)
levers.restoreFromDisk()

func listen(at path: String) -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        let b = Array(path.utf8.prefix(dst.count - 1))
        dst.copyBytes(from: b)
        dst[b.count] = 0
    }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard fd >= 0, bound == 0, Darwin.listen(fd, 4) == 0 else { log("cannot listen on \(path): \(errno)"); exit(1) }
    chmod(path, 0o666)       // the app runs as the user; who may talk is checked per connection
    return fd
}

/// Only the PowerCuff app binary may drive the levers.
func isPowerCuff(_ fd: Int32) -> Bool {
    var pid: pid_t = 0
    var len = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 else { return false }
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
    let path = String(cString: buf)
    let ok = path.hasSuffix("/PowerCuff.app/Contents/MacOS/PowerCuff")
    if !ok { log("rejected client pid \(pid) \(path)") }
    return ok
}

func handle(_ line: String) -> String {
    if line.hasPrefix("hello") { return HelperProtocol.encode(hello: levers.caps) }
    if line == "ping" { return "ok" }
    if let want = HelperProtocol.decodeSet(line) {
        let before = levers.state
        let (now, note) = levers.apply(want)
        if now != before { log("levers \(now)\(note.map { " (\($0))" } ?? "")") }
        return HelperProtocol.encode(state: now, note: note)
    }
    return "err"
}

let server = listen(at: socketPath)
log("listening on \(socketPath)")
var client: Int32 = -1
var buffer = Data()
var lastMessage = Date()
var lastFloorCheck = Date()

func dropClient() {
    if client >= 0 { close(client) }
    client = -1
    buffer = Data()
    if levers.state.any { log("client gone: releasing"); levers.releaseAll() }
}

while quitRequested == 0 {
    var fds = [pollfd(fd: server, events: Int16(POLLIN), revents: 0)]
    if client >= 0 { fds.append(pollfd(fd: client, events: Int16(POLLIN), revents: 0)) }
    if poll(&fds, nfds_t(fds.count), 250) < 0 && errno != EINTR { break }

    if fds[0].revents & Int16(POLLIN) != 0 {
        let c = accept(server, nil, nil)
        if c >= 0 {
            if anyClient || isPowerCuff(c) {
                dropClient()                // one app at a time; a new instance takes over from a clean state
                var one: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                client = c
                lastMessage = Date()
            } else {
                close(c)
            }
        }
    }

    if client >= 0, fds.count > 1, fds[1].revents != 0 {
        var chunk = [UInt8](repeating: 0, count: 512)
        let n = read(client, &chunk, chunk.count)
        if n <= 0 {
            dropClient()
        } else {
            buffer.append(contentsOf: chunk.prefix(n))
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                lastMessage = Date()
                let reply = Array((handle(line) + "\n").utf8)
                if reply.withUnsafeBytes({ write(client, $0.baseAddress, $0.count) }) != reply.count { dropClient(); break }
            }
            if buffer.count > 4096 { dropClient() }
        }
    }

    // The app keeps the lease alive several times a second; silence means it hung or was stopped.
    if levers.state.any, Date().timeIntervalSince(lastMessage) > HelperProtocol.leaseSeconds {
        log("lease expired: releasing")
        levers.releaseAll()
    }
    if Date().timeIntervalSince(lastFloorCheck) > 5 {
        lastFloorCheck = Date()
        levers.enforceFloor()
    }
}

log("exiting: releasing")
levers.releaseAll()
unlink(socketPath)
