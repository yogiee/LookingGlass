import Foundation

/// Reads the user's off-bundle model configuration — a role→model routing map — from
/// Application Support, so model role assignments survive app updates (Invariant #7) and can
/// be changed without editing the bundled `config.toml` (which a reinstall replaces).
///
/// **F2 foundation** (see `WORKSPACE/model-config-workflow.md`). This file is the future home
/// for the SIMPLE/MULTI presets. Today nothing *writes* it, so `activeMap()` returns `nil` by
/// default and `SidecarClient` sends no `models` field — the sidecar falls back to
/// `config.toml [models]`, i.e. identical behavior. Drop a `model_config.json` here to exercise
/// the override path end-to-end.
///
/// File shape (partial maps are fine — unspecified roles fall back to the sidecar default):
/// ```json
/// { "models": { "default": "…", "research": "…", "coding": "…",
///               "deep_research": "…", "specialist": "…", "hands": "…" } }
/// ```
enum ModelConfigStore {
    /// `~/Library/Application Support/LookingGlass/model_config.json`
    /// (same directory as `history.db`, the avatar, and `mcp_user_servers.json`).
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("LookingGlass", isDirectory: true)
                   .appendingPathComponent("model_config.json", isDirectory: false)
    }

    /// The active role→model map, or `nil` when no (valid, non-empty) config file exists —
    /// in which case the sidecar uses its shipped `config.toml [models]`.
    static func activeMap() -> [String: String]? {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [String: String],
              !models.isEmpty
        else { return nil }
        return models
    }
}
