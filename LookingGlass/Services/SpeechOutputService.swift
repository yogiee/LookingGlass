import AVFoundation
import Foundation
import Metal

/// Alice's spoken voice — the surface the app talks to.
///
/// Tier-1 utility on the `AppleIntelligenceService` pattern: availability-guarded, silent fallback,
/// callers never have to know whether speech is possible or which engine is speaking.
///
/// This type owns everything that is true regardless of engine: reducing markdown to a speakable layer,
/// publishing what's being spoken, reading settings, and choosing the engine. Engines live behind
/// `SpeechBackend`:
///
/// - **LIGHT** → `KokoroSpeechBackend` (Kokoro-82M on Core AI, in-process) once downloaded, else
///   `SystemSpeechBackend` (`AVSpeechSynthesizer`)
/// - **QUALITY / QUALITY+** → `NeuralSpeechBackend` (Alice's cloned voice, Qwen3-TTS in the sidecar)
///
/// **AUTO decides once, not continuously.** It resolves at launch and when something that changes the
/// answer changes — the chat model, the tier setting, what's installed — and never mid-reading. LIGHT and
/// the Qwen tiers are different speakers, so an AUTO that flapped under memory pressure would make Alice
/// change voice between replies.
@MainActor
final class SpeechOutputService: ObservableObject {
    static let shared = SpeechOutputService()

    /// What the speech layer is doing right now. Drives the play/stop button.
    @Published private(set) var activity: SpeechActivity = .idle

    /// The sidecar's last report on the neural voice; nil until it answers once.
    @Published private(set) var neuralStatus: NeuralVoiceStatus?

    /// What AUTO currently means, and why. nil until first resolved.
    @Published private(set) var autoDecision: VoiceTierResolver.Decision?

    /// Synthetic id for the Settings voice preview.
    static let previewID = "voice-preview"

    private let client = NeuralVoiceClient()
    private let system = SystemSpeechBackend()
    private let player = StreamingVoicePlayer()
    private lazy var kokoro: KokoroSpeechBackend = {
        let backend = KokoroSpeechBackend(player: player, fallback: system)
        backend.onStateChange = { [weak self] in self?.objectWillChange.send() }
        return backend
    }()
    private lazy var neural: [VoiceTier: NeuralSpeechBackend] = Dictionary(
        uniqueKeysWithValues: VoiceTier.neural.map {
            ($0, NeuralSpeechBackend(tier: $0, client: client, fallback: system, player: player))
        })

    /// The engine currently speaking (or preparing), so stop and live-rate reach the right one even if
    /// the tier setting changed mid-reading.
    private var speakingBackend: SpeechBackend?

    /// Invalidates in-flight backend callbacks. Bumped on every state change, so a late completion for a
    /// superseded utterance can't clobber the current one — `id` alone can't do this, because re-reading
    /// the same message reuses it.
    private var generation = 0

    private var pollTask: Task<Void, Never>?
    /// The inputs AUTO last resolved against; a defaults change only re-resolves when these move.
    private var lastResolveKey: String?

    private init() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        }
        // The sidecar starts with the app; keep asking until it answers, then resolve AUTO once.
        Task { [weak self] in
            for _ in 0..<45 {
                guard let self else { return }
                await self.refresh()
                if self.neuralStatus != nil {
                    self.optimizeLightIfNeeded()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Settings

    enum Keys {
        static let enabled = "voiceOutputEnabled"
        static let voice   = "ttsVoiceIdentifier"
        static let rate    = "ttsRate"
        static let tier    = "ttsVoiceTier"
        /// Kokoro's pack or blend. Separate from `voice` (an AVSpeech identifier) so neither engine is
        /// ever handed the other's id.
        static let kokoroVoice = "ttsKokoroVoice"
    }

    /// User toggle. Default true — speech is opt-out, like Apple Intelligence.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.enabled).map { ($0 as? Bool) ?? true } ?? true
    }

    /// The stored rate that means "normal pace". Settings persists an absolute value in this space for
    /// historical reasons (it was AVFoundation's scale); the backend protocol takes a multiple of natural
    /// pace, so this is the divisor that converts between them. Keeping the stored space unchanged means
    /// no migration for anyone who already tuned the slider.
    static let naturalRate: Double = 0.5

    /// Stored rate expressed as a multiple of natural pace — 1.0 is normal.
    var rateMultiple: Double {
        let stored = UserDefaults.standard.double(forKey: Keys.rate)
        guard stored > 0 else { return 1.0 }
        return stored / Self.naturalRate
    }

    private var storedVoiceID: String? {
        let id = UserDefaults.standard.string(forKey: Keys.voice) ?? ""
        return id.isEmpty ? nil : id
    }

    private var storedKokoroVoice: String? {
        let id = UserDefaults.standard.string(forKey: Keys.kokoroVoice) ?? ""
        return id.isEmpty ? nil : id
    }

    /// The voice-quality setting as chosen, AUTO included.
    var selectedTier: VoiceTier {
        VoiceTier(rawValue: UserDefaults.standard.string(forKey: Keys.tier) ?? "") ?? .auto
    }

    /// The tier actually in effect: AUTO resolved, and a neural tier that can't speak yet falling back to
    /// LIGHT (not installed, clip missing, sidecar down) — callers never get silence for a setting.
    var effectiveTier: VoiceTier {
        let wanted = selectedTier == .auto ? (autoDecision?.tier ?? .light) : selectedTier
        guard let backend = neural[wanted] else { return .light }
        return backend.readiness.canSpeak ? wanted : .light
    }

    private var backend: SpeechBackend {
        if let voice = neural[effectiveTier] { return voice }
        return lightUsesKokoro ? kokoro : system
    }

    /// LIGHT is Kokoro once it's downloaded; the system voice until then.
    var lightUsesKokoro: Bool { kokoro.isInstalled }

    /// True while Core AI compiles Kokoro for this Mac — ~2 minutes, once per OS build.
    var isOptimizingLight: Bool { kokoro.isOptimizing }

    // MARK: - State queries

    /// True while this id is being read — including the silent moment before audio starts, so a Stop
    /// control stays correct on a backend with real time-to-first-byte.
    func isSpeaking(_ id: String) -> Bool { activity.id == id }

    /// True whenever anything at all is being spoken or prepared, regardless of which message. The
    /// composer needs this to mute the mic and dim the spectrograph while Alice talks.
    var isActive: Bool { activity != .idle }

    /// True only during the pre-audio phase — the few hundred milliseconds a neural voice takes to
    /// produce its first sound. Always effectively false on the system engine.
    func isPreparing(_ id: String) -> Bool { activity == .preparing(id) }

    // MARK: - Speaking

    /// Play/stop the same message; start fresh if something else is speaking.
    func toggle(_ markdown: String, id: String, rate: Double? = nil) {
        if isSpeaking(id) { stop() } else { speak(markdown, id: id, rate: rate) }
    }

    /// Speak `markdown` aloud, cancelling anything already in flight. No-ops when the message reduces to
    /// nothing speakable (e.g. pure code).
    ///
    /// - Parameter rate: a pace for THIS reading only, as a multiple of natural pace (the report viewer's
    ///   temporary override). nil uses the Settings rate.
    func speak(_ markdown: String, id: String, rate: Double? = nil) {
        // The spoken layer, not the whole reply: bulleted comparisons and code are reading constructs and
        // stay on screen. What's *hearable* doesn't depend on which control started it.
        let text = SpokenLayer.make(from: markdown)
        let engine = backend
        guard !text.isEmpty, engine.readiness.canSpeak else { return }

        if let previous = speakingBackend, previous !== engine { previous.stop() }
        speakingBackend = engine
        generation += 1
        let token = generation
        activity = .preparing(id)

        let voiceID: String? = switch engine.id {
        case .system: storedVoiceID
        case .kokoro: storedKokoroVoice
        case .neural: nil
        }
        engine.speak(
            text,
            voiceID: voiceID,
            rate: rate ?? rateMultiple,
            onStart: { [weak self] in
                guard let self, self.generation == token else { return }
                self.activity = .speaking(id)
            },
            onFinish: { [weak self] in
                guard let self, self.generation == token else { return }
                self.activity = .idle
                self.speakingBackend = nil
            }
        )
    }

    /// Change the pace of what's playing right now. Live on the neural voice (mid-sentence); the system
    /// engine picks it up on its next utterance.
    func setLiveRate(_ multiple: Double) {
        speakingBackend?.setRate(multiple)
    }

    func stop() {
        generation += 1     // orphan any in-flight callbacks
        activity = .idle
        (speakingBackend ?? backend).stop()
        speakingBackend = nil
    }

    /// Warm the engine so the first utterance doesn't stall: a no-op on the system engine, a model load +
    /// kernel warm-up on a neural one (~0.6–1.2 s, which voice mode hides behind the chat model's reply).
    func warmUp() async {
        await backend.prepare()
        await refresh(resolve: false)
    }

    // MARK: - Voices (delegated to the active backend)

    var readiness: SpeechReadiness { backend.readiness }

    func voices() -> [VoiceOption] { backend.voices() }

    func defaultVoice() -> VoiceOption? { backend.defaultVoice() }

    var upgradeHint: SpeechUpgradeHint? { backend.upgradeHint }

    /// The system voices, for LIGHT's picker while Kokoro isn't downloaded.
    func systemVoices() -> [VoiceOption] { system.voices() }

    func defaultSystemVoice() -> VoiceOption? { system.defaultVoice() }

    /// Kokoro's packs (and Alice's blend), for LIGHT's picker once it is downloaded.
    func kokoroVoices() -> [VoiceOption] { kokoro.voices() }

    // MARK: - Neural voice: status, AUTO, downloads

    /// Re-read the sidecar's voice status and, unless told not to, re-resolve AUTO.
    func refresh(resolve: Bool = true) async {
        let status = await client.status()
        neuralStatus = status
        for backend in neural.values { backend.status = status }
        kokoro.status = status
        if resolve { await resolveAuto() }
    }

    /// Compile Kokoro for this Mac in the background when it will be needed and the OS has no compiled
    /// copy yet — just after it's downloaded, and after an OS update while LIGHT is the voice in use.
    /// Otherwise the first press of a speaker button would wait ~2 minutes.
    private func optimizeLightIfNeeded(force: Bool = false) {
        guard kokoro.isInstalled, !kokoro.isOptimizedForThisOS, !kokoro.isOptimizing else { return }
        guard force || effectiveTier == .light else { return }
        Task { await kokoro.prepare() }
    }

    /// Work out what AUTO means right now. Cheap; safe to call whenever its inputs may have changed.
    func resolveAuto() async {
        let budget = Double(MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 0) / 1e9
        let model = await primaryModelName()
        let host = UserDefaults.standard.string(forKey: "ollamaHost") ?? "http://localhost:11434"
        var footprint: Double?
        if let model { footprint = await PrimaryModelProbe.footprintGB(model: model, ollamaHost: host) }

        var installed = Set<VoiceTier>()
        var peaks: [VoiceTier: Double] = [:]
        for tier in VoiceTier.neural {
            guard let info = neuralStatus?.tier(tier) else { continue }
            peaks[tier] = info.peakGB
            if info.installed, neuralStatus?.reference.present == true, neuralStatus?.available == true {
                installed.insert(tier)
            }
        }
        autoDecision = VoiceTierResolver.resolve(.init(
            budgetGB: budget, primaryFootprintGB: footprint, installed: installed, peakGB: peaks))
        lastResolveKey = resolveKey()
    }

    /// Start downloading a tier's pinned model. Progress arrives through `neuralStatus`.
    func download(_ tier: VoiceTier) async -> String? {
        let error = await client.startDownload(tier)
        await refresh(resolve: false)
        pollWhileDownloading()
        return error?.message
    }

    func delete(_ tier: VoiceTier) async -> String? {
        if (speakingBackend as? NeuralSpeechBackend)?.tier == tier { stop() }
        if tier == .light {
            if speakingBackend === kokoro { stop() }
            // Before the files go: Core AI's compiled copy (~0.5 GB) is keyed by the bundles' hash files
            // and is NOT reclaimed when they're deleted.
            kokoro.clearCompiledCache()
        }
        if neuralStatus?.loadedTier == tier.sidecarID { await client.unload() }
        let error = await client.delete(tier)
        await refresh()
        return error?.message
    }

    private func pollWhileDownloading() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self.refresh(resolve: false)
                let running = self.neuralStatus?.tiers.values.contains { $0.download.isRunning } ?? false
                if !running {
                    await self.resolveAuto()          // a finished download can change AUTO's answer
                    self.optimizeLightIfNeeded(force: true)
                    self.pollTask = nil
                    return
                }
            }
        }
    }

    /// The chat model that will sit beside the voice: the user's explicit pick, else the sidecar's default.
    private func primaryModelName() async -> String? {
        let picked = UserDefaults.standard.string(forKey: "selectedModel") ?? ""
        if !picked.isEmpty { return picked }
        return await client.defaultChatModel()
    }

    private func resolveKey() -> String {
        let d = UserDefaults.standard
        return [d.string(forKey: "selectedModel") ?? "", d.string(forKey: "ollamaHost") ?? "",
                d.string(forKey: Keys.tier) ?? ""].joined(separator: "|")
    }

    /// Re-resolve AUTO only when an input actually moved — this fires for every defaults write.
    private func defaultsChanged() {
        guard lastResolveKey != nil, resolveKey() != lastResolveKey else { return }
        lastResolveKey = resolveKey()
        Task { await resolveAuto() }
    }

    // MARK: - Alice's voice clip

    /// Where the sidecar looks for the reference clip — user data, outside the bundle (Invariant #7).
    static var voiceDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LookingGlass/voice", isDirectory: true)
    }

    /// Install a reference clip and its transcript as Alice's voice.
    ///
    /// The clip and transcript are a PAIR: cloning treats the clip as the opening of a continuation, so a
    /// transcript that runs past the audio makes the model speak the missing words first. The transcript
    /// must be a `.txt` beside the `.wav` with the same name. Returns an error message, or nil on success.
    func importVoiceClip(from wav: URL) async -> String? {
        let transcript = wav.deletingPathExtension().appendingPathExtension("txt")
        guard FileManager.default.fileExists(atPath: transcript.path) else {
            return "Put the clip's exact transcript beside it as \(transcript.lastPathComponent)."
        }
        guard let text = try? String(contentsOf: transcript, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(transcript.lastPathComponent) is empty."
        }
        guard let file = try? AVAudioFile(forReading: wav) else { return "That file isn't readable audio." }
        let format = file.fileFormat
        guard format.sampleRate == 24_000, format.channelCount == 1,
              format.settings[AVLinearPCMBitDepthKey] as? Int == 16 else {
            return "The clip must be a 24 kHz, mono, 16-bit WAV."
        }
        let seconds = Double(file.length) / format.sampleRate
        guard (5...30).contains(seconds) else {
            return String(format: "The clip is %.1f s — cloning wants roughly 8–20 s of clean speech.", seconds)
        }

        let dir = Self.voiceDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (source, name) in [(wav, "alice_reference.wav"), (transcript, "alice_reference.txt")] {
                let target = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
            }
        } catch {
            return "Couldn't install the clip: \(error.localizedDescription)"
        }
        // A loaded model holds the old clip; drop it so the next reading clones the new one.
        await client.unload()
        await refresh()
        return nil
    }
}
