import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // `swift run` produces a bare executable (no .app bundle / Info.plist),
        // so the asset-catalog AppIcon never applies. Set the Dock icon at runtime.
        if let icon = Asset.nsImage("appicon") {
            NSApp.applicationIconImage = icon
        }
        // Start Sparkle only when running as a real .app (it needs the feed URL).
        if AppEnvironment.isBundledApp {
            _ = UpdaterService.shared
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct LookingGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sidecar = SidecarProcess()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sidecar)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                if AppEnvironment.isBundledApp {
                    Button("Check for Updates…") {
                        UpdaterService.shared.checkForUpdates()
                    }
                }
            }
        }
        .defaultSize(width: 960, height: 680)
    }
}
