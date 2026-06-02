import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by the Settings… menu item (⌘,) — RootView reveals the settings rail.
    static let openSettings = Notification.Name("openSettings")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Strong handle to the app's sidecar, assigned by `LookingGlassApp` on appear.
    /// Strong (not weak) on purpose: SwiftUI may release its `@StateObject` when the
    /// last window closes, which can precede `applicationWillTerminate`; holding it
    /// here guarantees the instance — and its child process handle — is still alive
    /// to stop at termination.
    var sidecar: SidecarProcess?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register Roboto Mono before any view renders so the chat voice picks
        // it up on first paint.
        ChatFont.registerBundled()
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

    func applicationWillTerminate(_ notification: Notification) {
        // Reap our sidecar so it isn't orphaned (and doesn't squat on port 8765
        // for the next launch). The Ollama model unloads separately via keep_alive.
        sidecar?.stop()
    }
}

@main
struct LookingGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sidecar = SidecarProcess()
    @StateObject private var store = ConversationStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sidecar)
                .environmentObject(store)
                .onAppear { appDelegate.sidecar = sidecar }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Standard ⌘, — reveals the Settings rail (no separate Settings scene).
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
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
