import Foundation

struct Message: Identifiable, Equatable {
    let id: UUID
    var role: Role
    var content: String
    var isStreaming: Bool
    var toolCalls: [ToolCall]
    /// The model that produced this turn, as resolved by the sidecar (captured from
    /// the `message_end` event). nil for user turns and pre-v3 history. Stamped
    /// per-message so a mid-conversation model switch is recorded turn-by-turn.
    var model: String?

    enum Role: String, Codable {
        case user
        case assistant
        /// UI-only notice persisted in history (e.g. "model no longer installed → switched
        /// to default"). Never sent to the model — filtered out of the request history.
        case system
    }

    init(id: UUID = UUID(), role: Role, content: String, isStreaming: Bool = false, toolCalls: [ToolCall] = [], model: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.toolCalls = toolCalls
        self.model = model
    }
}
