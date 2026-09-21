import CoreAI
import Foundation

/// The LIGHT voice: Kokoro-82M on Core AI, in-process, on the CPU.
///
/// Cheap where the Qwen tiers are expensive — ~0.8 GB of CPU memory and none of the Metal budget, so it
/// never competes with the chat model — at the cost of Alice's own voice: Kokoro speaks with fixed voice
/// packs (a different speaker from the cloned Qwen voice) and reads no emotion from the text.
///
/// Plays through the SAME `StreamingVoicePlayer` as the neural tiers, so the user's rate is applied by
/// `AVAudioUnitTimePitch` and the report viewer's slider acts mid-sentence here too. Kokoro's own `speed`
/// knob is left at 1.0: it is fixed per synthesised chunk and can't follow a live slider.
///
/// **First load compiles the model for this Mac (~2 minutes on an M1 Max)**, then Core AI caches the result
/// per process under `~/Library/Caches/coreai-cache/<OS build>/`. So the app optimises right after download
/// and again after an OS update, rather than making the first press of a speaker button wait two minutes.
/// Deleting the model clears that cache FIRST — it is ~0.5 GB and is not reclaimed when the model goes
/// (see the gotcha_coreai_specialization_cache_disk memory).
@MainActor
final class KokoroSpeechBackend: SpeechBackend {
    let id: SpeechBackendID = .kokoro

    /// Install state comes from the sidecar's downloader, pushed in by `SpeechOutputService`.
    var status: NeuralVoiceStatus?
    /// Called whenever `isOptimizing` changes, so the service can republish it.
    var onStateChange: (() -> Void)?

    private(set) var isOptimizing = false { didSet { onStateChange?() } }
    private(set) var lastLoadError: String?

    private var engine: KokoroTTS?
    private var loading: Task<KokoroTTS, Error>?
    private let player: StreamingVoicePlayer
    private let fallback: SpeechBackend

    private var task: Task<Void, Never>?
    private var pendingFinish: (@MainActor () -> Void)?
    private var lastUsed = Date.distantPast
    private var idleTask: Task<Void, Never>?

    /// Keep the engine resident this long after last use, then release its ~0.8 GB. A warm (cached) load
    /// is well under a second, so this is cheap to pay again.
    private static let keepAlive: Duration = .seconds(600)
    private static let optimizedBuildKey = "kokoroOptimizedForBuild"

    init(player: StreamingVoicePlayer, fallback: SpeechBackend) {
        self.player = player
        self.fallback = fallback
    }

    // MARK: - Files

    /// Where the sidecar's downloader puts the LIGHT tier — user data, outside the bundle (Invariant #7).
    /// `LG_TTS_MODELS_DIR` mirrors the sidecar's dev override; unset in the shipped app.
    static var modelDirectory: URL {
        if let dev = ProcessInfo.processInfo.environment["LG_TTS_MODELS_DIR"], !dev.isEmpty {
            return URL(fileURLWithPath: dev).appendingPathComponent("light", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LookingGlass/models/tts/light", isDirectory: true)
    }

    private static var graphs: [URL] {
        ["kokoro_predictor", "kokoro_prosody", "kokoro_vocoder"]
            .map { modelDirectory.appendingPathComponent("\($0).aimodel") }
    }

    private static var glue: URL { modelDirectory.appendingPathComponent("kokoro_host_glue") }

    /// Optional word → phoneme overrides (misaki US phonemes) for names no rule can reach.
    static var pronunciations: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LookingGlass/voice/pronunciations.json")
    }

    var isInstalled: Bool { status?.tier(.light)?.installed ?? false }

    // MARK: - Readiness

    var readiness: SpeechReadiness {
        guard isInstalled else {
            return .needsDownload(megabytes: (status?.tier(.light)?.downloadBytes ?? 360_000_000) / 1_000_000)
        }
        return engine == nil ? .needsWarmUp : .ready
    }

    /// True when Core AI's compiled copy for THIS OS build probably exists, i.e. a load will be fast.
    var isOptimizedForThisOS: Bool {
        UserDefaults.standard.string(forKey: Self.optimizedBuildKey) == Self.osBuild
    }

    private static var osBuild: String { ProcessInfo.processInfo.operatingSystemVersionString }

    func prepare() async {
        _ = try? await loadedEngine()
    }

    /// The loaded engine, loading it if needed. Concurrent callers share one load.
    private func loadedEngine() async throws -> KokoroTTS {
        if let engine { return engine }
        if let loading { return try await loading.value }
        guard isInstalled else {
            throw NeuralVoiceError(code: "not_installed", message: "LIGHT isn't downloaded yet.")
        }
        // A load without a cached compile for this OS takes ~2 minutes; say so in Settings.
        if !isOptimizedForThisOS { isOptimizing = true }
        let graphs = Self.graphs
        let glue = Self.glue
        let pron = FileManager.default.fileExists(atPath: Self.pronunciations.path) ? Self.pronunciations : nil
        let load = Task.detached(priority: .userInitiated) {
            try await KokoroTTS(predictorAt: graphs[0], prosodyAt: graphs[1], vocoderAt: graphs[2],
                                glueDir: glue, customPronunciations: pron)
        }
        loading = load
        defer {
            loading = nil
            isOptimizing = false
        }
        do {
            let tts = try await load.value
            engine = tts
            lastLoadError = nil
            UserDefaults.standard.set(Self.osBuild, forKey: Self.optimizedBuildKey)
            touch()
            return tts
        } catch {
            lastLoadError = error.localizedDescription
            throw error
        }
    }

    /// Drop the engine (and its ~0.8 GB). The compiled cache on disk stays, so the next load is fast.
    func unload() {
        engine = nil
        idleTask?.cancel()
        idleTask = nil
    }

    /// Clear Core AI's compiled copies of the three graphs. MUST run while the model files still exist:
    /// the cache is keyed by each bundle's hash file, so after deletion there is nothing to look it up by.
    func clearCompiledCache() {
        unload()
        for graph in Self.graphs where FileManager.default.fileExists(atPath: graph.path) {
            do { try AIModelCache.default.deleteEntries(for: graph) } catch {
                print("[tts] couldn't clear the Core AI cache for \(graph.lastPathComponent): \(error)")
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.optimizedBuildKey)
    }

    // MARK: - Voices

    /// Kokoro's voice packs (from the files, so no model load is needed to list them), with Alice's
    /// round-1 blend first. British packs lead: the reference Alice is a British English voice.
    func voices() -> [VoiceOption] {
        let dir = Self.glue.appendingPathComponent("voices")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".bin") }
            .map { String($0.dropLast(4)) }
        guard !names.isEmpty else { return [] }
        var options = [VoiceOption(id: Self.aliceBlend, name: "Alice blend", quality: "bf_alice + af_heart",
                                   language: "en-GB")]
        let ranked = names.sorted { lhs, rhs in
            let l = lhs.hasPrefix("bf_") ? 0 : lhs.hasPrefix("af_") ? 1 : 2
            let r = rhs.hasPrefix("bf_") ? 0 : rhs.hasPrefix("af_") ? 1 : 2
            return (l, lhs) < (r, rhs)
        }
        for name in ranked {
            let (display, language) = Self.describe(name)
            options.append(VoiceOption(id: name, name: display, quality: "", language: language))
        }
        return options
    }

    func defaultVoice() -> VoiceOption? { voices().first }

    var upgradeHint: SpeechUpgradeHint? { nil }

    /// The blend auditioned in round 1 (bf_alice 0.65 + af_heart 0.35): a Kokoro voice is a style tensor,
    /// so a weighted average of two packs is a coherent third speaker.
    static let aliceBlend = "bf_alice*0.65+af_heart*0.35"

    private static func describe(_ pack: String) -> (String, String) {
        let parts = pack.split(separator: "_", maxSplits: 1)
        guard parts.count == 2 else { return (pack, "") }
        let language = parts[0].hasPrefix("b") ? "en-GB" : parts[0].hasPrefix("a") ? "en-US" : ""
        let gender = parts[0].hasSuffix("f") ? "female" : "male"
        return ("\(parts[1].capitalized) (\(gender))", language)
    }

    // MARK: - Speaking

    func speak(
        _ text: String,
        voiceID: String?,
        rate: Double,
        onStart: @escaping @MainActor () -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        cancelInFlight()
        pendingFinish = onFinish
        let voice = resolveVoice(voiceID)

        task = Task { [weak self] in
            guard let self else { return }
            // A box, not a var: the chunk callback is @Sendable, and Swift 6 forbids mutating a captured
            // var from one. Main-actor isolated, so every read and write happens on the same actor.
            let started = StartFlag()
            do {
                let tts = try await self.loadedEngine()
                try Task.checkCancellation()
                try self.player.begin(sampleRate: Double(KokoroTTS.sampleRate), rate: rate, onDrained: { [weak self] in
                    self?.finishPending()
                })
                // Synthesis runs off the main actor (KokoroTTS is nonisolated); each finished chunk hops
                // back to be scheduled. Cancelling this task stops synthesis between chunks.
                // Strong capture on purpose: this task already holds `self` for its whole run, and a
                // `[weak self]` here would be a captured var inside a @Sendable closure (a Swift 6 error).
                try await tts.synthesizeStreaming(text, voice: voice) { chunk in
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.player.enqueue(chunk)
                        if !started.value {
                            started.value = true
                            onStart()
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                self.touch()
                if started.value { self.player.endOfStream() } else { self.finishPending() }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.player.stop()
                guard !started.value else {
                    print("[tts] Kokoro broke mid-reading: \(error.localizedDescription)")
                    self.finishPending()
                    return
                }
                print("[tts] Kokoro failed before audio: \(error.localizedDescription) — using the system voice")
                self.pendingFinish = nil
                self.fallback.speak(text, voiceID: nil, rate: rate, onStart: onStart, onFinish: onFinish)
            }
        }
    }

    func setRate(_ rate: Double) {
        player.rate = rate
    }

    func stop() {
        cancelInFlight()
        fallback.stop()
    }

    private func resolveVoice(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return Self.aliceBlend }
        // A stored id can name a pack that no longer exists; the blend's packs ship with every install.
        if id.contains("+") || voices().contains(where: { $0.id == id }) { return id }
        return Self.aliceBlend
    }

    private func cancelInFlight() {
        task?.cancel()
        task = nil
        player.stop()
        finishPending()
    }

    private func finishPending() {
        let finish = pendingFinish
        pendingFinish = nil
        finish?()
    }

    // MARK: - Idle release

    private func touch() {
        lastUsed = Date()
        guard idleTask == nil else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.keepAlive)
                guard let self else { return }
                // Release only when nothing is in flight (a reading holds `pendingFinish` until it ends).
                if Date().timeIntervalSince(self.lastUsed) >= 600, self.pendingFinish == nil {
                    self.engine = nil
                    self.idleTask = nil
                    print("[tts] Kokoro released after idling")
                    return
                }
            }
        }
    }
}

/// "Has audio started yet", shared between a speaking task and its @Sendable chunk callback.
@MainActor
private final class StartFlag {
    var value = false
}
