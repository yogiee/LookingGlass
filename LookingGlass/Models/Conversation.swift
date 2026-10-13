import Foundation

/// A row in the chat-history sidebar. Lightweight projection of a `conversations`
/// row plus a preview snippet (the latest message) for display. The full message
/// list is loaded on demand via `ConversationStore.loadMessages`.
struct ConversationListItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let preview: String
    let updatedAt: Date
}

/// What the chat pane's top pill shows for the open conversation: its title, the
/// one-line summary (nil until Apple Intelligence has written one), the latest
/// message as a fallback description, and the owning project for the colour dot.
/// Fetched by id rather than taken from the sidebar list, because the open chat
/// can sit outside the sidebar's current view (another project, or root).
struct ActiveConversationInfo: Equatable {
    let id: UUID
    let title: String
    let summary: String?
    let preview: String
    let project: ProjectListItem?

    /// The description line: the summary when there is one, else the latest message.
    var description: String { summary ?? preview }
}
