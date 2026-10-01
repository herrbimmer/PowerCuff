import XCTest
@testable import PowerCuffCore

/// Read-only: documents which charge/adapter keys this Mac has (the helper writes them as root).
final class LeverKeysTests: XCTestCase {
    func testLeverKeysShapeMatchesHelper() throws {
        guard let smc = SMCConnection() else { throw XCTSkip("no SMC") }
        let chte = smc.info("CHTE"), ch0b = smc.info("CH0B"), chie = smc.info("CHIE"), ch0j = smc.info("CH0J"), ch0i = smc.info("CH0I")
        print("LEVERKEYS CHTE=\(String(describing: chte)) CH0B=\(String(describing: ch0b)) CHIE=\(String(describing: chie)) CH0J=\(String(describing: ch0j)) CH0I=\(String(describing: ch0i))")
        print("LEVERKEYS values CHTE=\(smc.read("CHTE") ?? []) CHIE=\(smc.read("CHIE") ?? [])")
        // The helper writes `[on, 0, 0, …]` sized to the key, so sizes must be known and small.
        for k in [chte, chie] { if let k { XCTAssertLessThanOrEqual(k.size, 4) } }
        XCTAssertTrue(chte != nil || ch0b != nil, "no charge-inhibit key on this Mac")
    }

    private func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = out; p.standardError = out
        try? p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// The install scripts only get one shot at running as root: lint them (without executing) first.
    func testInstallScriptsAreValid() throws {
        let dir = NSTemporaryDirectory() + "pc-inst-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let plistFile = dir + "/h.plist"
        try HelperInstall.plist.write(toFile: plistFile, atomically: true, encoding: .utf8)
        let lint = run("/usr/bin/plutil", ["-lint", plistFile])
        XCTAssertEqual(lint.0, 0, lint.1)
        let dict = NSDictionary(contentsOfFile: plistFile)
        XCTAssertEqual(dict?["Label"] as? String, HelperProtocol.label)
        XCTAssertEqual((dict?["ProgramArguments"] as? [String])?.first, HelperProtocol.installedBinary)
        XCTAssertEqual(dict?["KeepAlive"] as? Bool, true)

        for (name, script) in [("install", HelperInstall.installScript(helper: "/Users/o'neil/My App/PowerCuffHelper")),
                               ("uninstall", HelperInstall.uninstallScript)] {
            let f = dir + "/\(name).sh"
            try script.write(toFile: f, atomically: true, encoding: .utf8)
            let r = run("/bin/sh", ["-n", f])
            XCTAssertEqual(r.0, 0, "\(name): \(r.1)")
        }
        // Paths with spaces and quotes survive quoting.
        XCTAssertTrue(HelperInstall.installScript(helper: "/a b/c'd").contains("'/a b/c'\\''d'"))
        // Removal touches only our own two files.
        XCTAssertEqual(HelperInstall.uninstallScript.components(separatedBy: "rm -f ").count, 2)
        XCTAssertFalse(HelperInstall.uninstallScript.contains("rm -rf"))
    }
}
