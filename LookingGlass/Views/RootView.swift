import SwiftUI
import AppKit

// NSVisualEffectView with .behindWindow blending.
// .underWindowBackground is the only material that works with .behindWindow.
// colorScheme is propagated via updateNSView so live appearance changes work.
struct VibrancyBackground: NSViewRepresentable {
    let colorScheme: ColorScheme?

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // Keep the view's own appearance in sync; nil means inherit from NSApp
        nsView.appearance = nsAppearance(for: colorScheme)
    }
}

struct WindowChromeConfigurator: NSViewRepresentable {
    let colorScheme: ColorScheme?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            // NSApp.appearance is the app-level authority SwiftUI observes —
            // setting it nil reverts to system immediately and triggers
            // environment re-evaluation without needing a focus change.
            NSApp.appearance = nsAppearance(for: colorScheme)
        }
    }
}

// nil → follow system; .dark / .light → force that appearance on the NSWindow/NSView
private func nsAppearance(for scheme: ColorScheme?) -> NSAppearance? {
    switch scheme {
    case .dark:  return NSAppearance(named: .darkAqua)
    case .light: return NSAppearance(named: .aqua)
    default:     return nil
    }
}

struct RootView: View {
    @EnvironmentObject private var sidecar: SidecarProcess
    @Environment(\.colorScheme) private var systemColorScheme

    @AppStorage("railSelectionRaw") private var railSelectionRaw = RailTab.chats.rawValue
    @AppStorage("colorSchemeRaw")   private var colorSchemeRaw   = AppColorScheme.system.rawValue
    @AppStorage("fontSize")         private var fontSize         = 14.0
    @AppStorage("lineHeight")       private var lineHeight       = 1.2
    @AppStorage("backgroundStyle")  private var backgroundStyleRaw = BackgroundStyle.glass.rawValue
    @State private var sidebarVisible = true

    private var backgroundStyle: BackgroundStyle {
        BackgroundStyle(rawValue: backgroundStyleRaw) ?? .glass
    }

    private var railTab: RailTab {
        RailTab(rawValue: railSelectionRaw) ?? .chats
    }

    // nil if "System", otherwise the forced preference
    private var preferredColorScheme: ColorScheme? {
        (AppColorScheme(rawValue: colorSchemeRaw) ?? .system).colorScheme
    }

    // The actually-active scheme, resolving "System" from the environment
    private var activeColorScheme: ColorScheme {
        preferredColorScheme ?? systemColorScheme
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            // Base glass in both modes.
            VibrancyBackground(colorScheme: preferredColorScheme)
            // Dark mode: dark frosting so desktop detail is obscured.
            if activeColorScheme == .dark {
                Color.black.opacity(0.38)
            }
            // Wonderland: faint themed backdrop layered over the glass at fixed
            // low opacity — a graphical hint, not a full takeover. Bottom-anchored
            // via an explicit GeometryReader frame so the mushroom landscape stays
            // pinned to the window floor. Light mode needs more opacity (pale art).
            if backgroundStyle == .wonderland {
                GeometryReader { geo in
                    Asset.image(activeColorScheme == .dark ? "bg-dark" : "bg-light")
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                        .clipped()
                }
                .opacity(activeColorScheme == .dark ? 0.22 : 0.42)
                .allowsHitTesting(false)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            RailView(activeTab: railTab, sidebarOpen: sidebarVisible) { tapped in
                if tapped == railTab {
                    withAnimation(.spring(duration: 0.22)) { sidebarVisible.toggle() }
                } else {
                    railSelectionRaw = tapped.rawValue
                    if !sidebarVisible {
                        withAnimation(.spring(duration: 0.22)) { sidebarVisible = true }
                    }
                }
            }

            if sidebarVisible {
                SidebarView(tab: railTab)
                    .frame(width: 260)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            Rectangle()
                .fill(.separator.opacity(0.4))
                .frame(width: 0.5)

            ChatView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 500)
        .background {
            backgroundLayer.ignoresSafeArea()
        }
        .background(WindowChromeConfigurator(colorScheme: preferredColorScheme).frame(width: 0, height: 0))
        .preferredColorScheme(preferredColorScheme)
        .environment(\.chatFontSize, fontSize)
        .environment(\.chatLineHeight, lineHeight)
        .task { sidecar.start() }
    }
}
