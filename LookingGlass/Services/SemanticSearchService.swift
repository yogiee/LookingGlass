import Foundation

/// Semantic embeddings for history search, via **embeddinggemma** through the
/// local Ollama that already backs chat.
///
/// This is a deliberate Swift-direct call to Ollama (not routed through the
/// sidecar): history, embeddings, and the search UI all live frontend (GRDB), so
/// keeping the embed here keeps the whole feature self-contained and skips a
/// pointless relay. It's a leaf UI utility — the same class as
/// `AppleIntelligenceService` (on-device inference for titles/summaries) — not
/// part of Alice's agent loop, which stays sidecar-owned (invariant #3).
///
/// > Why embeddinggemma and not NaturalLanguage: on-device `NLContextualEmbedding`
/// > (mean-pooled) and `NLEmbedding.sentenceEmbedding` were both measured
/// > (2026-07-21) to be UNUSABLE for semantic ranking on technical text —
/// > anisotropy / OOV collapse. embeddinggemma:300m discriminates correctly, and
/// > small bundled candidates (bge-small, granite-30m) were mushier. See the
/// > `feature_semantic_history_search` memory.
/// >
/// > Forward note: this leaf utility is the natural first candidate to move onto
/// > the ANE via Core AI on macOS 27 (Bet 1 — ANE offload) — a ~one-file swap of
/// > the producer below. The storage/ranking layer stays put.
///
/// **Pure compute + one HTTP call.** It never touches the database;
/// `ConversationStore` owns storage of the BLOBs. An `actor` so calls serialize
/// cleanly and stay off the main thread. Everything degrades gracefully: `embed`
/// returns nil (Ollama down, model missing, disabled) and callers fall back to
/// the existing FTS search.
actor SemanticSearchService {
    static let shared = SemanticSearchService()
    private init() {}

    /// The embedding model. Flipping this flips `activeTag`, which makes the
    /// backfill re-embed every message under the new tag.
    private static let model = "embeddinggemma:300m"

    /// ~6k chars keeps us comfortably under the model's context; longer messages
    /// are truncated (FTS still covers their exact terms). Chunk+mean-pool for very
    /// long messages is a possible future refinement.
    private static let maxChars = 6000

    /// Tag stored with each vector: the source + scheme that produced it. Ranking
    /// only compares same-tag vectors; a change flips it so stale rows re-embed.
    /// `.conv` = conversation-level, prefixed-retrieval scheme.
    var activeTag: String { "ollama.\(Self.model).conv" }

    var isAvailable: Bool { userEnabled }

    private nonisolated var userEnabled: Bool {
        // Defaults OFF — see ConversationStore.semanticEnabled (re-enable when the
        // Feature-B summary embedding path lands).
        UserDefaults.standard.object(forKey: "semanticSearchEnabled")
            .map { ($0 as? Bool) ?? false } ?? false
    }

    private nonisolated var ollamaHost: String {
        let host = UserDefaults.standard.string(forKey: "ollamaHost") ?? "http://localhost:11434"
        return host.isEmpty ? "http://localhost:11434" : host
    }

    // MARK: - Embedding

    /// embeddinggemma is instruction-tuned and expects retrieval **prefixes** — without
    /// them, embeddings blur and generic text (greetings, "Sure thing!") floats to the
    /// top (measured 2026-07-21). Queries and documents get different prefixes.

    /// Embed a search query (unit-normalized, cosine == dot). nil on disable/empty/failure.
    func embedQuery(_ query: String) async -> [Float]? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return await embedRaw("task: search result | query: \(q)")
    }

    /// Embed a conversation's gist (title + topic-bearing text) as a retrieval document,
    /// returning the vector + the tag that produced it.
    func embedConversation(title: String, text: String) async -> (vector: [Float], tag: String)? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(text.prefix(Self.maxChars))
        let doc = "title: \(t.isEmpty ? "none" : t) | text: \(body.isEmpty ? t : body)"
        guard let v = await embedRaw(doc) else { return nil }
        return (v, activeTag)
    }

    private func embedRaw(_ prepared: String) async -> [Float]? {
        guard isAvailable else { return nil }
        let input = String(prepared.prefix(Self.maxChars + 64))  // + room for the short prefix
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        guard let url = URL(string: ollamaHost.appending("/api/embed")) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try? JSONEncoder().encode(EmbedRequest(model: Self.model, input: input))
        guard req.httpBody != nil else { return nil }

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(EmbedResponse.self, from: data),
              let raw = decoded.embeddings.first, !raw.isEmpty
        else { return nil }

        return Self.normalized(raw)
    }

    private struct EmbedRequest: Encodable { let model: String; let input: String }
    private struct EmbedResponse: Decodable { let embeddings: [[Float]] }

    // MARK: - Ranking

    /// Cosine similarity. Vectors are stored unit-normalized, so this is a dot
    /// product; guards against dimension mismatch (a different model tag).
    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot
    }

    // MARK: - Serialization (Float32 BLOB)

    nonisolated static func data(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated static func vector(from data: Data) -> [Float] {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.stride == 0 else { return [] }
        return data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }

    // MARK: - Helpers

    private nonisolated static func normalized(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        let norm = sumSq.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}
