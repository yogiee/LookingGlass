import Foundation
import SwiftUI

/// App-wide source of truth for the chat-model list. Fetches the sidecar's enriched
/// `/models` (live installed ∩ capable, joined with the opinion registry) and shares it
/// via `.environmentObject` so the side panel, the input-bar switcher, and the
/// stale-model guard all read one consistent set. Refreshed at launch and on demand.
@MainActor
final class ModelCatalog: ObservableObject {
    @Published private(set) var models: [ModelInfo] = []
    @Published private(set) var loaded = false      // a fetch has completed at least once

    private let client = SidecarClient()

    /// Re-fetch from the sidecar. Called at launch (Guard A: launch refresh) and when a
    /// picker opens. Only overwrites on a non-empty result so a transient sidecar/Ollama
    /// blip doesn't blank a good list mid-session.
    func refresh(ollamaHost: String) async {
        let fresh = await client.fetchModels(ollamaHost: ollamaHost)
        if !fresh.isEmpty || !loaded {
            models = fresh
        }
        loaded = true
    }

    var names: [String] { models.map(\.name) }

    func info(for name: String) -> ModelInfo? { models.first { $0.name == name } }

    /// Whether a model is currently installed + chat-capable. `loaded == false` means we
    /// haven't heard from the sidecar yet — treat as "unknown, don't act" (Guard B only
    /// fires once we actually have a list, to avoid false stale-model switches at startup).
    func contains(_ name: String) -> Bool { names.contains(name) }
}
