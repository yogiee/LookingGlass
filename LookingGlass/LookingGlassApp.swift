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
        }
        .defaultSize(width: 960, height: 680)
    }
}
