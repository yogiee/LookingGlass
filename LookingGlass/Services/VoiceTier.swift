import Foundation

/// The voice-quality setting: AUTO, or one of three tiers.
///
/// - **LIGHT** — Kokoro-82M on Core AI, in the app, on the CPU (~0.8 GB, no Metal budget). ~360 MB download.
///   Until it's downloaded, LIGHT is the built-in system voice (`AVSpeechSynthesizer`).
/// - **QUALITY** — Alice's cloned voice on Qwen3-TTS 0.6B (6-bit), in the sidecar.
/// - **QUALITY+** — the same voice on Qwen3-TTS 1.7B (6-bit).
///
/// Both Qwen tiers clone the same reference clip and measure as the same speaker (cosine ~0.997), so
/// moving between them doesn't change who is talking. LIGHT is a different speaker — which is why AUTO
/// decides once and doesn't flap. Decisions and measurements: the `decision_tts_tiers` memory.
enum VoiceTier: String, CaseIterable, Identifiable, Sendable {
    case auto
    case light
    case quality
    case qualityPlus = "quality_plus"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "AUTO"
        case .light: "LIGHT"
        case .quality: "QUALITY"
        case .qualityPlus: "QUALITY+"
        }
    }

    var summary: String {
        switch self {
        case .auto: "Picks the best voice that fits beside your chat model."
        case .light: "A light on-device voice (Kokoro). ~360 MB download, runs on the CPU."
        case .quality: "Alice's own voice. ~1.9 GB download."
        case .qualityPlus: "Alice's own voice, larger model. ~2.7 GB download."
        }
    }

    /// The sidecar's id for a tier whose voice the SIDECAR synthesises; nil for AUTO and LIGHT.
    var sidecarID: String? {
        switch self {
        case .quality, .qualityPlus: rawValue
        case .auto, .light: nil
        }
    }

    /// The id of this tier's downloadable model. LIGHT has one too: Kokoro runs in the app, but its files
    /// come through the sidecar's downloader so all three tiers share one install path and progress UI.
    var modelID: String? {
        switch self {
        case .light, .quality, .qualityPlus: rawValue
        case .auto: nil
        }
    }

    /// The neural tiers, best first.
    static let neural: [VoiceTier] = [.qualityPlus, .quality]
}

/// Decides what AUTO means on this machine.
///
/// Headroom is measured, not banded by total RAM: `recommendedMaxWorkingSetSize` minus the footprint of
/// the chat model that will actually be loaded. That is what makes the small-model fleet path upgrade
/// the voice automatically — a smaller primary leaves more room.
///
/// The margin is deliberately generous. On the single-big-model path the realistic worst case is the
/// chat model + a voice + an image model at once, and measured physical-RAM pressure bit *before* the
/// GPU cap did (macOS swapped the chat model out at 24.9 GB of models on a 32 GB Mac). Yogi's call: this
/// 32 GB + gemma4:26b machine lands on QUALITY, not QUALITY+. That needs a margin between ~4.9 and
/// ~5.8 GB; 5.3 sits mid-band so measurement drift can't flip it. The same margin also absorbs MLX
/// chat models' KV cache, which grows with context because MLX ignores `num_ctx`.
enum VoiceTierResolver {
    static let marginGB = 5.3

    struct Inputs: Equatable {
        /// Metal's recommended working set for this Mac, in GB (1e9 bytes).
        var budgetGB: Double
        /// Footprint of the chat model that will be resident, in GB; nil when it couldn't be measured.
        var primaryFootprintGB: Double?
        /// Neural tiers downloaded and usable.
        var installed: Set<VoiceTier>
        /// Synthesis peak per neural tier, GB, from the sidecar's tier table.
        var peakGB: [VoiceTier: Double]
    }

    struct Decision: Equatable {
        let tier: VoiceTier
        /// Plain-language reason for Settings.
        let reason: String
        /// A better tier that would fit but isn't downloaded — worth offering, never fetched silently.
        let couldUpgradeTo: VoiceTier?
    }

    static func resolve(_ inputs: Inputs) -> Decision {
        guard let primary = inputs.primaryFootprintGB else {
            // Can't measure (Ollama unreachable, model not pulled). Prefer QUALITY over LIGHT whenever
            // it exists — that is the stated rule — but don't gamble on QUALITY+ blind.
            if inputs.installed.contains(.quality) {
                return Decision(tier: .quality,
                                reason: "Couldn't measure your chat model, so AUTO stays on QUALITY.",
                                couldUpgradeTo: nil)
            }
            return Decision(tier: .light,
                            reason: "Couldn't measure your chat model, and no Alice voice is downloaded.",
                            couldUpgradeTo: nil)
        }

        let headroom = inputs.budgetGB - primary
        func fits(_ tier: VoiceTier) -> Bool {
            guard let peak = inputs.peakGB[tier] else { return false }
            return peak + marginGB <= headroom
        }

        let bestFitting = VoiceTier.neural.first(where: fits)
        let chosen = VoiceTier.neural.first { fits($0) && inputs.installed.contains($0) }
        let room = String(format: "%.1f GB", max(0, headroom))

        guard let chosen else {
            let upgrade = bestFitting
            return Decision(
                tier: .light,
                reason: upgrade == nil
                    ? "Only \(room) left beside your chat model — not enough for Alice's voice."
                    : "\(upgrade!.label) would fit (\(room) free) but isn't downloaded.",
                couldUpgradeTo: upgrade)
        }
        let upgrade: VoiceTier? = (bestFitting != nil && bestFitting != chosen) ? bestFitting : nil
        return Decision(tier: chosen,
                        reason: "\(room) free beside your chat model.",
                        couldUpgradeTo: upgrade)
    }
}
