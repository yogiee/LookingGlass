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

    /// Generate a short conversation title from the first user + assistant exchange.
    func generateConversationTitle(userMessage: String, assistantReply: String) async -> String? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(
            instructions: "Generate a short conversation title of 5–7 words. Return only the title, no quotes, no trailing punctuation."
        )
        let prompt = "User: \(userMessage.prefix(200))\nAssistant: \(assistantReply.prefix(400))"
        guard let response = try? await session.respond(to: prompt) else { return nil }
        let title = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title.prefix(80))
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

    /// Expand a search query with synonyms for better full-text search coverage.
    /// Returns nil for very short queries where expansion adds no value.
    func expandSearchQuery(_ query: String) async -> String? {
        guard isAvailable, query.count > 3 else { return nil }
        let session = LanguageModelSession(
            instructions: "Expand this search query with 2–3 synonyms or closely related terms, space-separated. Return only the expanded query, nothing else."
        )
        guard let response = try? await session.respond(to: query) else { return nil }
        let expanded = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return expanded.isEmpty ? nil : expanded
    }
}
