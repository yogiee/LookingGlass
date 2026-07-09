import Foundation

/// Shared state driving the full-window report overlay.
/// Owned by RootView, read/written by ChatView + MessageBubble via @EnvironmentObject.
@MainActor
final class ReportPanelState: ObservableObject {
    /// What the panel renders: a markdown file on disk (research reports) or an
    /// in-memory markdown string (heavy chat responses shown as snippet cards).
    enum Source: Equatable {
        case file(String)
        case text(String)
    }

    @Published var source: Source? = nil
    @Published var isVisible = false

    func show(_ path: String) { source = .file(path); isVisible = true }
    func show(text: String) { source = .text(text); isVisible = true }
    func dismiss() { isVisible = false }
}
