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

    /// How this text came to exist. nil for assistant turns and pre-v8 history.
    var source: Source?

    /// For `.corrected` messages, the raw dictation before it was fixed.
    /// Kept so the pair can be diffed — a correction is only informative next to
    /// what it corrected.
    var dictationOriginal: String?

    /// Provenance, and the reason it matters: the vocabulary harvest must treat
    /// these differently. Dictated text is the recogniser's *own output*, so
    /// feeding it back as recognition bias compounds errors — measured on real
    /// history, the misspelling "Nasik" outnumbered the correction "Nashik" 3:1
    /// and would have won on frequency.
    enum Source: String, Codable {
        /// Typed by hand. Ground truth.
        case typed
        /// Straight from dictation, unreviewed. Machine output — never votes.
        case dictated
        /// Dictated, then corrected by hand before sending. The most valuable
        /// class we have: machine output that a human verified, carrying its
        /// own before-and-after in `dictationOriginal`.
        case corrected
    }

    enum Role: String, Codable {
        case user
        case assistant
        /// UI-only notice persisted in history (e.g. "model no longer installed → switched
        /// to default"). Never sent to the model — filtered out of the request history.
        case system
    }

    init(id: UUID = UUID(), role: Role, content: String, isStreaming: Bool = false, toolCalls: [ToolCall] = [], model: String? = nil,
         source: Source? = nil, dictationOriginal: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.toolCalls = toolCalls
        self.model = model
        self.source = source
        self.dictationOriginal = dictationOriginal
    }
}
