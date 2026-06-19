import Foundation

/// One chat-capable model as reported by the sidecar's enriched `/models`:
/// live facts (name, capable, location) LEFT JOIN our opinion registry
/// (`sidecar/models.toml` → role/tier/speed/recommended/note). Models the registry
/// doesn't know about arrive with `untested == true` — shown, not hidden.
struct ModelInfo: Codable, Identifiable, Equatable, Hashable {
    let name: String
    var capable: Bool = true
    var role: String? = nil
    var tier: String? = nil
    var tokps: Double? = nil
    var ramGB: Double? = nil
    var location: String? = nil
    var recommended: Bool = false
    var note: String? = nil
    var untested: Bool = false

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, capable, role, tier, tokps
        case ramGB = "ram_gb"
        case location, recommended, note, untested
    }

    var isCloud: Bool { (location == "cloud") || name.contains("cloud") }

    /// Portable speed label derived from measured tok/s (reference machine).
    /// Bands from `feedback_speed_thresholds`: >40 comfortable · >20 workable · <20 slow.
    var speedBand: String? {
        guard let t = tokps else { return nil }
        if t >= 40 { return "fast" }
        if t >= 20 { return "ok" }
        return "slow"
    }

    /// Short badge text for the picker: cloud marker > role/tier nuance handled by UI.
    var speedBadge: String? {
        if let t = tokps { return "~\(Int(t)) tok/s" }
        return nil
    }
}

/// Decodes the sidecar `/models` response: `{"models": [ {...} ], "error": "…"?}`.
struct ModelsResponse: Codable {
    let models: [ModelInfo]
    var error: String? = nil
}
