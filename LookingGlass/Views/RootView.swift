import SwiftUI
import AppKit

/// Shared edges of the floating chrome. The sidebar's top lines up with the chat's
/// top pill and its bottom with the composer, so all three sit between the same two
/// lines (WORKSPACE/mockups/chat-pill-bar.html, A5). Equal top and bottom: 14 pt at
/// the top read as cramped against the window edge next to a 30 pt bottom.
enum ChromeInsets {
    static let top: CGFloat = 30
    static let bottom: CGFloat = 30
}

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

/// AppKit Liquid Glass behind the whole window. Stock glass follows System Settings →
/// Appearance (Clear / Tinted) and Reduce Transparency on its own — the same reason
/// IPMSGX's glass tracks those settings with no code of its own. A trial against the
/// frosted backdrop (Settings → Style → Window Backdrop): Clear may prove too
/// see-through behind long text.
struct GlassBackdrop: NSViewRepresentable {
    let colorScheme: ColorScheme?

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = 0          // the window's own corner mask does the rounding
        view.contentView = NSView()
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.appearance = nsAppearance(for: colorScheme)
    }
}

/// Transparent overlay that tells AppKit "don't drag the window from here."
/// Place as .background() on any content area where text selection is needed.
/// The invisible title-bar strip (fullSizeContentView + titlebarAppearsTransparent)
/// remains draggable because AppKit handles it separately via window chrome.
private struct NoDragBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { _NoDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class _NoDragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

/// Restores native title-bar behavior on the hidden title bar: drag to move, double-click to
/// zoom. The content covers the title-bar strip (fullSizeContentView) and NoDragBackground makes
/// it non-draggable, so AppKit's own handling never sees these events — we forward them here.
private struct TitleBarBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { _Strip() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class _Strip: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)               // double-click → zoom (maximize)
            } else {
                window?.performDrag(with: event)       // single drag → move the window
            }
        }
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
    @AppStorage("ollamaHost")       private var ollamaHost       = "http://localhost:11434"
    @AppStorage("windowBackdrop")   private var windowBackdropRaw = WindowBackdrop.liquidGlass.rawValue
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var sidebarVisible = true

    @StateObject private var systemMonitor = SystemMonitor()
    @StateObject private var toolCallStore = ToolCallStore()
    @StateObject private var reportPanel = ReportPanelState()
    @StateObject private var modelCatalog = ModelCatalog()
    @StateObject private var imageViewer = ImageViewerState()

    private var railTab: RailTab {
        RailTab(rawValue: railSelectionRaw) ?? .chats
    }

    private var preferredColorScheme: ColorScheme? {
        (AppColorScheme(rawValue: colorSchemeRaw) ?? .system).colorScheme
    }

    private var activeColorScheme: ColorScheme {
        preferredColorScheme ?? systemColorScheme
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        switch WindowBackdrop(rawValue: windowBackdropRaw) ?? .liquidGlass {
        case .liquidGlass:
            GlassBackdrop(colorScheme: preferredColorScheme)
        case .frosted:
            // Frosted desktop blur + a dark tint for readability. No tint under Reduce
            // Transparency: AppKit already makes the vibrancy view opaque there.
            VibrancyBackground(colorScheme: preferredColorScheme)
            if !reduceTransparency {
                Color.black.opacity(activeColorScheme == .dark ? 0.35 : 0.08)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            RailView(activeTab: railTab, sidebarOpen: sidebarVisible, systemMonitor: systemMonitor) { tapped in
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
                    .environmentObject(systemMonitor)
                    .environmentObject(toolCallStore)
                    .environmentObject(modelCatalog)
                    .frame(width: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    // System glass, not a material: it follows the Liquid Glass and
                    // Reduce Transparency settings, and draws its own rim.
                    .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
                    .padding(.top, ChromeInsets.top)
                    .padding(.bottom, ChromeInsets.bottom)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            ChatView()
                .environmentObject(toolCallStore)
                .environmentObject(modelCatalog)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Title-bar strip: drag to move, double-click to zoom (clear of the traffic lights).
        // Only as tall as the gap above the sidebar and the chat's top pill, so it never
        // sits over their controls; the pill moves the window itself.
        .overlay(alignment: .top) {
            TitleBarBehavior()
                .frame(height: ChromeInsets.top)
                .padding(.leading, 72)
        }
        .blur(radius: reportPanel.isVisible ? 6 : 0, opaque: false)
        .animation(.easeInOut(duration: 0.28), value: reportPanel.isVisible)
        .background(NoDragBackground())
        .focusEffectDisabled()
        .ignoresSafeArea()  // let padding(.vertical,8) measure from actual window edges
        .frame(minWidth: 900, minHeight: 500)
        .background {
            backgroundLayer.ignoresSafeArea()
        }
        .background(WindowChromeConfigurator(colorScheme: preferredColorScheme).frame(width: 0, height: 0))
        .preferredColorScheme(preferredColorScheme)
        .environment(\.chatFontSize, fontSize)
        .environment(\.chatLineHeight, lineHeight)
        .environmentObject(reportPanel)
        .environmentObject(imageViewer)
        // Full-window image lightbox — covers rail + sidebar + chat. The lightbox
        // animates its own open/close (hero-zoom + backdrop fade), so no transition
        // here; it calls dismiss() after its close animation finishes.
        .overlay {
            if let path = imageViewer.path {
                LightboxView(path: path, sourceRect: imageViewer.sourceRect) {
                    imageViewer.dismiss()
                }
                .ignoresSafeArea()
                .zIndex(200)
            }
        }
        // Full-window report panel overlay — covers rail + sidebar + chat
        .overlay {
            if reportPanel.isVisible, let source = reportPanel.source {
                ResearchReportPanel(source: source, fontSize: fontSize, lineHeight: lineHeight) {
                    withAnimation(.easeInOut(duration: 0.28)) { reportPanel.dismiss() }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .ignoresSafeArea()
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: reportPanel.isVisible)
        .task {
            sidecar.start()
            systemMonitor.ollamaHost = ollamaHost
            systemMonitor.start()
            // Alice's environment: begin gathering location (CoreLocation) + weather (Open-Meteo).
            // Requests permission on first launch; silently no-ops if denied.
            AmbientContextService.shared.start()
            // Guard A: refresh the model registry on every launch so newly pulled /
            // removed models are reflected without manual action.
            await modelCatalog.refresh(ollamaHost: ollamaHost)
        }
        // Re-fetch once the sidecar reports healthy (covers the launch race where the
        // first refresh runs before the sidecar is up).
        .onChange(of: sidecar.status) { _, newStatus in
            if newStatus == .running {
                Task { await modelCatalog.refresh(ollamaHost: ollamaHost) }
            }
        }
        // The top pill's project name: show that project's chats in the sidebar.
        .onReceive(NotificationCenter.default.publisher(for: .revealChatsSidebar)) { _ in
            railSelectionRaw = RailTab.chats.rawValue
            if !sidebarVisible {
                withAnimation(.spring(duration: 0.22)) { sidebarVisible = true }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            railSelectionRaw = RailTab.settings.rawValue
            if !sidebarVisible {
                withAnimation(.spring(duration: 0.22)) { sidebarVisible = true }
            }
        }
    }
}
