import SwiftUI
import AppKit

/// Slide-in overlay panel that renders a markdown document — a saved research
/// report (`.file`) or a heavy chat response opened from its snippet card
/// (`.text`). Appears over the chat area (sidebar/rail stay visible).
///
/// Rendering is a WKWebView (`ReportWebView`): WebKit lays the document out in
/// its own WebContent process, so even a pathological table-heavy report can't
/// stall the app — the freeze class the old in-panel MarkdownUI renderer (and
/// chat bubbles before it) suffered from. Closing the panel unmounts the view
/// and reclaims the web process.
struct ResearchReportPanel: View {
    let source: ReportPanelState.Source
    let fontSize: Double
    let lineHeight: Double
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var content: String = ""
    /// Web page finished loading (fires fast — layout continues off-process).
    @State private var pageLoaded = false
    /// Delayed flag so content only reveals after the slide-in transition settles —
    /// prevents the jarring "text pops before panel" visual on open.
    @State private var slideSettled = false

    private var contentVisible: Bool { pageLoaded && slideSettled }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }

                // Panel — 65% of window width, slides in from the right
                VStack(spacing: 0) {
                    header
                    Divider()
                    // The webview mounts immediately (it must, to start loading)
                    // and fades in once loaded + the slide-in has settled.
                    ZStack {
                        ReportWebView(markdown: content,
                                      fontSize: fontSize,
                                      lineHeight: lineHeight,
                                      colorScheme: colorScheme,
                                      onFinishLoad: { pageLoaded = true })
                            .opacity(contentVisible ? 1 : 0)
                        if !contentVisible {
                            ProgressView()
                        }
                    }
                    .animation(.easeIn(duration: 0.15), value: contentVisible)
                }
                .frame(width: geo.size.width * 0.65)
                .background(.ultraThinMaterial)
            }
        }
        .ignoresSafeArea()
        .task {
            loadContent()
            try? await Task.sleep(for: .milliseconds(320))
            slideSettled = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
            Spacer()
            // Export button
            Button {
                exportReport()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Export as Markdown")
            // Close button
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Loading

    private func loadContent() {
        switch source {
        case .file(let path):
            content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "_Could not load report._"
        case .text(let markdown):
            content = markdown
        }
    }

    private var exportFilename: String {
        switch source {
        case .file(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .text: return "alice-response.md"
        }
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportFilename
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
