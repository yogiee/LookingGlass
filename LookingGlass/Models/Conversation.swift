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
