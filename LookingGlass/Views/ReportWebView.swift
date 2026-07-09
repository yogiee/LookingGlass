import SwiftUI
import WebKit
import AppKit

/// WKWebView-backed markdown renderer for the report panel, borrowing the shell of
/// Typa's `MarkdownWebView` (link-out delegate, transparent background, CSS-key
/// reloads). WebKit lays the document out in its WebContent process, so an
/// arbitrarily large report can never stall the app's main thread — the reason
/// this exists (see decision_report_viewer_webview).
struct ReportWebView: NSViewRepresentable {
    let markdown: String
    let fontSize: Double
    let lineHeight: Double
    let colorScheme: ColorScheme
    /// Fired when the page finishes loading — the panel holds its spinner until then.
    var onFinishLoad: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // Static HTML only — nothing needs JS, so none is allowed. Model output
        // is untrusted input; between this and cmark's raw-HTML stripping there
        // is no script path into the page.
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")   // panel material shows through
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = false

        context.coordinator.lastRenderKey = renderKey
        wv.loadHTMLString(pageHTML(), baseURL: nil)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.parent = self
        // Reload only when an input that affects the rendered page changes
        // (content, scheme, type settings) — not on every SwiftUI update pass.
        if context.coordinator.lastRenderKey != renderKey {
            context.coordinator.lastRenderKey = renderKey
            wv.loadHTMLString(pageHTML(), baseURL: nil)
        }
    }

    private var renderKey: String {
        "\(colorScheme)|\(fontSize)|\(lineHeight)|\(markdown.count)|\(markdown.hashValue)"
    }

    private func pageHTML() -> String {
        MarkdownHTML.page(markdown: markdown,
                          colorScheme: colorScheme,
                          fontSize: fontSize,
                          lineHeight: lineHeight,
                          accentHex: NSColor.controlAccentColor.cssHexString)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ReportWebView
        var lastRenderKey = ""

        init(_ parent: ReportWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onFinishLoad?()
        }

        // Links open in the default browser, never inside the panel.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
