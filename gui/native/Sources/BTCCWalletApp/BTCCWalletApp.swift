import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        clearSavedWindowState()
        DispatchQueue.main.async {
            self.restoreMainWindow()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.restoreMainWindow()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.forEach { $0.makeKeyAndOrderFront(nil) }
            }
        }
    }

    private func restoreMainWindow() {
        guard let window = NSApp.windows.first else { return }
        let screen = window.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        guard visibleFrame != .zero else { return }

        let size = window.frame.size
        let x = visibleFrame.midX - size.width / 2
        let y = visibleFrame.midY - size.height / 2
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    private func clearSavedWindowState() {
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys.filter {
            $0.contains("NSWindow Frame") || $0.contains("AppWindow")
        }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
    }
}

@main
struct BTCCWalletApp: App {
    @StateObject private var runner = MinerRunner()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(runner)
                .frame(minWidth: 820, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
