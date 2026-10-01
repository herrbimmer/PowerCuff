import Foundation
import PowerCuffCore

/// Runs the helper install/remove scripts (see `HelperInstall`) as root through the standard administrator dialog.
enum HelperInstaller {
    static var bundledHelperPath: String? {
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PowerCuffHelper").path
        if FileManager.default.isExecutableFile(atPath: inBundle) { return inBundle }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("PowerCuffHelper").path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil
    }

    static func installScript(helper: String?) -> String? { helper.map(HelperInstall.installScript(helper:)) }
    static var uninstallScript: String { HelperInstall.uninstallScript }

    /// Blocks until the dialog is answered; call off the main thread.
    static func runAsAdmin(_ script: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // The script travels as an argument, so it needs no AppleScript escaping.
        p.arguments = ["-e", "on run argv", "-e", "do shell script (item 1 of argv) with administrator privileges",
                       "-e", "end run", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
