import SwiftUI
import AppKit

// NSVisualEffectView with .behindWindow blending — the only way to get true
// frosted-desktop blur in SwiftUI. SwiftUI materials alone can't reach outside
// the window frame to sample the desktop.
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
            NSApp.appearance = nsAppearance(for: colorScheme)
        }
    }
}

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

    private var preferredColorScheme: ColorScheme? {
        (AppColorScheme(rawValue: colorSchemeRaw) ?? .system).colorScheme
    }

    private var activeColorScheme: ColorScheme {
        preferredColorScheme ?? systemColorScheme
    }

    // Wonderland backdrop fills the window. Glass mode darkens the desktop for readability.
    @ViewBuilder
    private var backgroundLayer: some View {
        if backgroundStyle == .wonderland || backgroundStyle == .wonderlandWalk {
            let name: String = {
                let walk = backgroundStyle == .wonderlandWalk
                return activeColorScheme == .dark
                    ? (walk ? "bg-dark-walk" : "bg-dark")
                    : (walk ? "bg-light-walk" : "bg-light")
            }()
            GeometryReader { geo in
                Asset.image(name)
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                    .clipped()
            }
            .opacity(0.9)
        } else {
            // Glass mode: frosted desktop blur + dark tint for readability.
            VibrancyBackground(colorScheme: preferredColorScheme)
            Color.black.opacity(activeColorScheme == .dark ? 0.35 : 0.08)
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
                    .frame(width: 380)
                    .padding(.vertical, 8)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    // Hairline border so the panel reads against the frosted backdrop
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                            .padding(.vertical, 8)
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            ChatView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()  // let padding(.vertical,8) measure from actual window edges
        .frame(minWidth: 900, minHeight: 500)
        .background {
            backgroundLayer.ignoresSafeArea()
        }
        .background(WindowChromeConfigurator(colorScheme: preferredColorScheme).frame(width: 0, height: 0))
        .preferredColorScheme(preferredColorScheme)
        .environment(\.chatFontSize, fontSize)
        .environment(\.chatLineHeight, lineHeight)
        .task { sidecar.start() }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            railSelectionRaw = RailTab.settings.rawValue
            if !sidebarVisible {
                withAnimation(.spring(duration: 0.22)) { sidebarVisible = true }
            }
        }
    }
}
