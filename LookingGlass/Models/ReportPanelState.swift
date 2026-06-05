import Foundation

/// Shared state driving the full-window research report overlay.
/// Owned by RootView, read/written by ChatView via @EnvironmentObject.
@MainActor
final class ReportPanelState: ObservableObject {
    @Published var path: String? = nil
    @Published var isVisible = false

    func show(_ path: String) { self.path = path; isVisible = true }
    func dismiss() { isVisible = false }
}
