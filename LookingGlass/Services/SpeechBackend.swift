import Foundation

/// The engine-neutral contract for Alice's spoken voice.
///
/// Phase 0 of the audio track. `AVSpeechSynthesizer` is still the only
/// implementation — this exists so the *second* one can land without rewriting
/// the call sites, and so voice mode and STT aren't built on assumptions that
/// only hold for the system engine.
///
/// Concretely, `AVSpeechSynthesizer` starts instantly, has nothing to load, and
/// vends `AVSpeechSynthesisVoice` objects. A neural backend (the measured
/// Qwen3-TTS candidate) has ~450ms time-to-first-byte, a lazy ~1.9GB model load,
/// a multi-gigabyte download before it can run at all, and speakers that are not
/// `AVSpeechSynthesisVoice` in any form. Every one of those differences is
/// represented below, even though nothing exercises them yet.
///
/// See the `design_alice_acoustic_voice` memory for the measurements this shape
/// is derived from.

// MARK: - Voices

/// A voice offered by some backend, described without reference to the engine
/// that vends it. `id` is backend-scoped and is what gets persisted in settings.
struct VoiceOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// The engine's own quality tier, already humanised — "Premium", "Compact".
    /// Empty when the engine doesn't grade its voices.
    let quality: String
    /// Locale tag, or empty when the engine doesn't model locale.
    let language: String

    /// One-line description for pickers: "Isha · Premium · en-IN".
    var label: String {
        [name, quality, language].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Readiness

/// Whether a backend can speak, and what it would cost to get there.
enum SpeechReadiness: Equatable, Sendable {
    /// Can speak now, with no first-utterance penalty.
    case ready
    /// Usable, but the first utterance pays a one-off model load. Call
    /// `prepare()` ahead of time to hide it.
    case needsWarmUp
    /// Assets must be fetched before this backend can speak at all.
    case needsDownload(megabytes: Int)
    /// Cannot run on this machine or in this build.
    case unavailable(reason: String)

    /// True when `speak` can be called and will produce audio.
    var canSpeak: Bool {
        switch self {
        case .ready, .needsWarmUp: return true
        case .needsDownload, .unavailable: return false
        }
    }
}

/// A backend-specific "this could sound better if you downloaded something"
/// nudge. The system engine uses it to point at Spoken Content, where enhanced
/// and premium voices are a free download; a neural backend would use it to
/// offer its model. nil when there is nothing to suggest.
struct SpeechUpgradeHint {
    let message: String
    let buttonTitle: String
    /// Optional smaller print under the button — e.g. the manual menu path.
    let detail: String?
    let action: @MainActor () -> Void
}

// MARK: - Activity

/// What the speech layer is doing, and for which message.
///
/// `preparing` is the state that does not exist in `AVSpeechSynthesizer`'s world
/// and is the main reason this abstraction is worth having: a neural backend is
/// audibly silent for a few hundred milliseconds after the user clicks, and the
/// UI has to be able to say so rather than looking dead. The system backend
/// passes through it in a few milliseconds.
enum SpeechActivity: Equatable {
    case idle
    /// Loading or synthesising. No audio yet.
    case preparing(String)
    /// Audio is playing.
    case speaking(String)

    /// The id being spoken or prepared, if any.
    var id: String? {
        switch self {
        case .idle: return nil
        case .preparing(let id), .speaking(let id): return id
        }
    }
}

// MARK: - Backend

/// Identifies a backend for settings persistence and selection.
enum SpeechBackendID: String, CaseIterable, Sendable {
    /// `AVSpeechSynthesizer` — always present, no download, no load.
    case system
    /// Alice's cloned voice: Qwen3-TTS on MLX in the sidecar (the QUALITY / QUALITY+ tiers).
    case neural
    /// Kokoro-82M on Core AI, in-process on the CPU (the LIGHT tier, once downloaded).
    case kokoro
}

/// An engine that can turn plain text into speech.
///
/// Implementations receive text that has *already* been reduced by
/// `SpeechText` — they are never handed markdown and must not try to parse it.
@MainActor
protocol SpeechBackend: AnyObject {
    var id: SpeechBackendID { get }

    /// Re-evaluated on access; a backend can become ready when the user
    /// downloads something, so callers should not cache this.
    var readiness: SpeechReadiness { get }

    /// Voices this engine offers, best first. May be empty.
    func voices() -> [VoiceOption]

    /// The automatic pick when the user hasn't chosen a voice.
    func defaultVoice() -> VoiceOption?

    /// See `SpeechUpgradeHint`. nil when there's nothing to offer.
    var upgradeHint: SpeechUpgradeHint? { get }

    /// Warm the engine so the first utterance doesn't stall. Idempotent, and a
    /// no-op where there is nothing to load. Safe to call speculatively.
    func prepare() async

    /// Speak already-reduced plain text.
    ///
    /// - Parameters:
    ///   - voiceID: a `VoiceOption.id` from this backend, or nil for automatic.
    ///     A stored id can name a voice the user has since deleted, so
    ///     implementations must fall back rather than fail.
    ///   - rate: speaking pace as a multiple of the engine's natural pace —
    ///     1.0 is normal, 1.3 is brisk. Deliberately not any one engine's
    ///     native scale.
    ///   - onStart: audio has actually begun. Fires after any time-to-first-byte.
    ///   - onFinish: the utterance ended, completed or cancelled. Exactly once,
    ///     including when `stop()` cut it short, and including when it never
    ///     started.
    func speak(
        _ text: String,
        voiceID: String?,
        rate: Double,
        onStart: @escaping @MainActor () -> Void,
        onFinish: @escaping @MainActor () -> Void
    )

    /// Cancel anything in flight. Must still deliver the pending `onFinish`.
    func stop()

    /// Change the pace of what is playing NOW, as a multiple of natural pace.
    ///
    /// For the report viewer's slider, which must act mid-sentence: a change that waited for the next
    /// sentence reads as "the slider did nothing" when the current one is long. Engines that can't
    /// retime audio already in flight (the system engine sets rate per utterance) keep the default no-op
    /// and pick the new rate up on the next `speak`.
    func setRate(_ rate: Double)
}

extension SpeechBackend {
    func setRate(_ rate: Double) {}
}
