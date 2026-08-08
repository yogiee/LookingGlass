import Foundation

/// Alice's spoken voice — the surface the app talks to.
///
/// Tier-1 utility on the `AppleIntelligenceService` pattern: availability-guarded,
/// silent fallback, callers never have to know whether speech is possible. Nothing
/// here touches the sidecar — the system engine is purely client-side, so no agent,
/// tool or SSE contract changes.
///
/// This type owns everything that is true regardless of engine: reducing markdown
/// to a speakable layer, publishing what's being spoken, and reading settings. The
/// engine itself lives behind `SpeechBackend`, so a second one can land without
/// touching a single call site here or in the views.
@MainActor
final class SpeechOutputService: ObservableObject {
    static let shared = SpeechOutputService()

    /// What the speech layer is doing right now. Drives the play/stop button.
    @Published private(set) var activity: SpeechActivity = .idle

    /// Synthetic id for the Settings voice preview.
    static let previewID = "voice-preview"

    /// The active engine. Only one exists today; when a second lands this becomes
    /// a resolution off `Keys.backend` rather than a constant.
    private let backend: SpeechBackend = SystemSpeechBackend()

    /// Invalidates in-flight backend callbacks. Bumped on every state change, so
    /// a late completion for a superseded utterance can't clobber the current one
    /// — `id` alone can't do this, because re-reading the same message reuses it.
    private var generation = 0

    private init() {}

    // MARK: - Settings

    enum Keys {
        static let enabled = "voiceOutputEnabled"
        static let voice   = "ttsVoiceIdentifier"
        static let rate    = "ttsRate"
        // Reserved for backend selection once there is more than one engine.
        static let backend = "ttsBackend"
    }

    /// User toggle. Default true — speech is opt-out, like Apple Intelligence.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.enabled).map { ($0 as? Bool) ?? true } ?? true
    }

    /// The stored rate that means "normal pace". Settings persists an absolute
    /// value in this space for historical reasons (it was AVFoundation's scale);
    /// the backend protocol takes a multiple of natural pace, so this is the
    /// divisor that converts between them. Keeping the stored space unchanged
    /// means no migration for anyone who already tuned the slider.
    static let naturalRate: Double = 0.5

    /// Stored rate expressed as a multiple of natural pace — 1.0 is normal.
    private var rateMultiple: Double {
        let stored = UserDefaults.standard.double(forKey: Keys.rate)
        guard stored > 0 else { return 1.0 }
        return stored / Self.naturalRate
    }

    private var storedVoiceID: String? {
        let id = UserDefaults.standard.string(forKey: Keys.voice) ?? ""
        return id.isEmpty ? nil : id
    }

    // MARK: - State queries

    /// True while this id is being read — including the silent moment before
    /// audio starts, so a Stop control stays correct on a backend with real
    /// time-to-first-byte.
    func isSpeaking(_ id: String) -> Bool { activity.id == id }

    /// True only during the pre-audio phase. Always false on the system engine,
    /// which starts effectively instantly; voice mode will use this to show that
    /// a neural backend is working rather than dead.
    func isPreparing(_ id: String) -> Bool { activity == .preparing(id) }

    // MARK: - Speaking

    /// Play/stop the same message; start fresh if something else is speaking.
    func toggle(_ markdown: String, id: String) {
        if isSpeaking(id) { stop() } else { speak(markdown, id: id) }
    }

    /// Speak `markdown` aloud, cancelling anything already in flight.
    /// No-ops when the message reduces to nothing speakable (e.g. pure code).
    func speak(_ markdown: String, id: String) {
        let text = SpeechText.make(from: markdown)
        guard !text.isEmpty, backend.readiness.canSpeak else { return }

        generation += 1
        let token = generation
        activity = .preparing(id)

        backend.speak(
            text,
            voiceID: storedVoiceID,
            rate: rateMultiple,
            onStart: { [weak self] in
                guard let self, self.generation == token else { return }
                self.activity = .speaking(id)
            },
            onFinish: { [weak self] in
                guard let self, self.generation == token else { return }
                self.activity = .idle
            }
        )
    }

    func stop() {
        generation += 1     // orphan any in-flight callbacks
        activity = .idle
        backend.stop()
    }

    /// Warm the engine so the first utterance doesn't stall. Free and idempotent;
    /// a no-op on the system engine, real work on one with a model to load.
    func warmUp() async {
        await backend.prepare()
    }

    // MARK: - Voices (delegated to the active backend)

    var readiness: SpeechReadiness { backend.readiness }

    func voices() -> [VoiceOption] { backend.voices() }

    func defaultVoice() -> VoiceOption? { backend.defaultVoice() }

    var upgradeHint: SpeechUpgradeHint? { backend.upgradeHint }
}
