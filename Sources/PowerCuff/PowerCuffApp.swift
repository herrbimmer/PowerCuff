import SwiftUI
import AppKit
import PowerCuffCore

/// Entry point. `--restore-brightness` is run by the safety watchdog after the app died while the display was
/// dimmed: put the backlight back and exit without starting anything else.
@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--restore-brightness") {
            DisplayDimmer.restoreSaved()
            exit(0)
        }
        PowerCuffApp.main()
    }
}

struct PowerCuffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = PowerModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(PowerModel.shared.showInDock ? .regular : .accessory)
        if ProcessInfo.processInfo.environment["POWERCUFF_OPEN_POPOVER"] != nil {
            // Dev aid for screenshots: click our own status item once it exists.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Self.clickStatusItem() }
        }
    }

    /// Every way out (menu, Cmd-Q, logout, shutdown) ends here: nothing may stay throttled.
    func applicationWillTerminate(_ notification: Notification) {
        PowerModel.shared.shutdown()
    }

    private static func clickStatusItem() {
        func button(in v: NSView) -> NSStatusBarButton? {
            if let b = v as? NSStatusBarButton { return b }
            for s in v.subviews { if let b = button(in: s) { return b } }
            return nil
        }
        for w in NSApp.windows {
            if let v = w.contentView, let b = button(in: v) { b.performClick(nil); return }
        }
    }
}

struct MenuBarLabel: View {
    let model: PowerModel

    var body: some View {
        HStack(spacing: 4) {
            if let img = MenuBarIcon.image {
                Image(nsImage: img)
            } else {
                Image(systemName: "bolt.fill")
            }
            if let w = model.snapshot?.controlledW {
                Text("\(Int(w.rounded()))W").monospacedDigit()
                    .contentTransition(.numericText(value: w))
                    .animation(model.motion, value: Int(w.rounded()))
            }
        }
    }
}

enum MenuBarIcon {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }()
}
