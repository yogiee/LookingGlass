import Foundation

@MainActor
class ToolCallStore: ObservableObject {
    @Published var entries: [ToolCallEntry] = []

    func recordStart(id: String, tool: String, argsJSON: String, conversationId: UUID?) {
        let entry = ToolCallEntry(
            id: id,
            tool: tool,
            status: .running,
            argsPreview: Self.makeArgsPreview(argsJSON),
            timestamp: Date(),
            conversationId: conversationId
        )
        entries.insert(entry, at: 0)
        prune()
    }

    func recordResult(id: String, success: Bool, result: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].status = success ? .success : .failed
        entries[idx].resultSnippet = result.isEmpty ? nil : String(result.prefix(300))
    }

    // MARK: - Helpers

    private static func makeArgsPreview(_ json: String) -> String {
        guard
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            !obj.isEmpty
        else {
            return String(json.prefix(100))
        }
        let pairs = obj.map { k, v -> String in
            let vs = "\(v)"
            let truncated = vs.count > 60 ? String(vs.prefix(60)) + "…" : vs
            return "\(k): \(truncated)"
        }
        return pairs.joined(separator: "  ·  ")
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-3600)
        if entries.count > 200 || entries.last.map({ $0.timestamp < cutoff }) == true {
            entries = Array(entries.filter { $0.timestamp > cutoff }.prefix(200))
        }
    }
}
