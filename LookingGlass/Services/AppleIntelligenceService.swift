import Foundation
import FoundationModels

/// On-device Apple Intelligence utilities — title generation, summarization, search expansion.
///
/// Every method returns nil silently when FM is unavailable or the user has disabled it.
/// Callers never guard against the unavailable case; they just fall back to whatever they
/// were doing before.
@MainActor
final class AppleIntelligenceService {
    static let shared = AppleIntelligenceService()
    private init() {}

    private let model = SystemLanguageModel.default

    /// Whether the hardware and OS support Apple Intelligence.
    var isSupported: Bool { model.isAvailable }

    /// Whether FM should be used right now (supported + user-enabled).
    var isAvailable: Bool {
        isSupported && userEnabled
    }

    private var userEnabled: Bool {
        // Default true when the key has never been set.
        UserDefaults.standard.object(forKey: "appleIntelligenceEnabled")
            .map { ($0 as? Bool) ?? true } ?? true
    }

    // MARK: - Utilities

    /// Generate a short conversation title from a user + assistant exchange, or nil when the exchange has
    /// no topic to name yet. Asked as plain text, the on-device model invents a topic for a greeting
    /// ("Hello there" → "Exciting trends in urban planning") and ignores an instruction to decline;
    /// a guided `hasTopic` field sorted 12/12 greetings from real openers (2026-10-13).
    func generateConversationTitle(userMessage: String, assistantReply: String) async -> String? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: "Name the topic of this conversation, if it has one yet.")
        let prompt = "User: \(userMessage.prefix(200))\nAssistant: \(assistantReply.prefix(400))"
        guard let response = try? await session.respond(to: prompt, generating: ConversationTitle.self),
              response.content.hasTopic else { return nil }
        let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”.")).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : String(title.prefix(80))
    }

    /// Describe what a conversation is about, for the chat pane's top pill. The pill
    /// clips it to one line and the hover card shows it whole, so it can run a little
    /// long — but it reads as a description of the topic, never as a chat reply.
    func generateConversationSummary(title: String, transcript: String) async -> String? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(
            instructions: """
                Describe what this conversation is about and where it has got to, in one or two \
                sentences and under 40 words. Write it as a description of the topic in the third \
                person, not as a reply. Return only the description, no preamble or quotes.
                """
        )
        let prompt = "Title: \(title)\n\n\(transcript)"
        guard let response = try? await session.respond(to: prompt) else { return nil }
        let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        return summary.isEmpty ? nil : String(summary.prefix(320))
    }

    /// Generate a one-line description for a memory entry.
    func generateMemorySummary(_ text: String) async -> String? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(
            instructions: "Summarize in one short sentence under 15 words. Return only the sentence."
        )
        guard let response = try? await session.respond(to: String(text.prefix(1200))) else { return nil }
        let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }
}

@Generable
struct ConversationTitle {
    @Guide(description: "True only if the user has raised a specific subject, task or question. False for greetings, pleasantries and small talk such as hello, good morning or how are you.")
    var hasTopic: Bool
    @Guide(description: "A 3 to 7 word title naming that subject, or an empty string when hasTopic is false.")
    var title: String
}
