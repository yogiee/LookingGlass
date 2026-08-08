import AVFoundation
import Foundation
import Speech

/// Alice's ear — on-device speech-to-text.
///
/// Sprint 3C core. Built on macOS 26's `SpeechAnalyzer` + `SpeechTranscriber`,
/// **not** the legacy `SFSpeechRecognizer` (`WORKSPACE/audio-pipeline-plan.md` is
/// stale on that point). Everything runs on this Mac; nothing is uploaded.
///
/// Mirrors `SpeechOutputService`: `@MainActor` singleton, availability-guarded,
/// published state for the UI, silent-ish failure with a readable message.
///
/// ## Module choice
/// `SpeechTranscriber`, not `DictationTranscriber`. Both exist in macOS 26 and
/// the tradeoff is real: `DictationTranscriber` has explicit `.punctuation` and
/// `.emoji` transcription options plus `ContentHint` (`.farField`,
/// `.atypicalSpeech`, `.customizedLanguage`), none of which `SpeechTranscriber`
/// exposes. `SpeechTranscriber` is the higher-accuracy general model, is the one
/// with an `isAvailable` guard, and is what the roadmap locked. ⚠ Whether it
/// punctuates on its own needs an ear-check on first run — if it doesn't,
/// `DictationTranscriber` is the swap, and only `makeTranscriber()` changes.
@MainActor
final class SpeechInputService: ObservableObject {
    static let shared = SpeechInputService()

    // MARK: - State

    enum State: Equatable {
        /// This machine or build can't transcribe at all.
        case unavailable(String)
        case idle
        /// Reserving a locale, downloading assets, or warming the model. Can be
        /// slow the very first time — assets are a real download.
        case preparing
        /// Mic is live.
        case listening
        /// Draining the last results after the user stopped.
        case finishing
    }

    @Published private(set) var state: State = .idle
    /// Text the recogniser has committed to.
    @Published private(set) var finalizedText = ""
    /// The in-flight guess, replaced as the recogniser changes its mind. Render
    /// this differently (dimmed) — it is not yet a commitment.
    @Published private(set) var volatileText = ""
    @Published private(set) var errorMessage: String?

    /// Everything heard so far, committed plus in-flight.
    var transcript: String {
        [finalizedText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A finished utterance, plus what the recogniser was unsure of.
    struct Utterance: Sendable {
        let text: String
        /// Words flagged below the confidence floor. Empty when it was confident.
        let uncertain: [String]
        /// The cue to stop and let Yogi look before this is sent.
        var needsReview: Bool { !uncertain.isEmpty }
    }

    /// Words the recogniser doubted during this utterance, in order of appearance.
    private var uncertainWords: [String] = []

    /// True when this listening session was started by a *click* rather than a
    /// hold, i.e. the composer is latched into voice mode.
    ///
    /// Can only be known on release — a press is ambiguous until it ends — so it
    /// starts false and gets promoted. Nothing user-visible depends on it during
    /// the press itself; it decides whether Alice narrates her reply afterwards.
    @Published private(set) var isLatched = false

    func markLatched() { isLatched = true }

    /// Lowest confidence seen in the last utterance, or nil when the recogniser
    /// reported none at all. Surfaced in the mic tooltip purely so the floor can
    /// be tuned against real numbers instead of guessed at.
    @Published private(set) var lastMinConfidence: Double?

    /// The word that scored `lastMinConfidence`.
    ///
    /// The score alone can't tune the floor: a weakest-word reading of 0.39
    /// means "the floor is about right" if that word was transcribed correctly,
    /// and "the floor is far too low" if it wasn't. Naming the word is what
    /// makes the number actionable at a glance.
    @Published private(set) var lastWeakestWord: String?

    /// Below this, a **content** word is worth a second look.
    ///
    /// Calibrated against measured values rather than guessed: in real dictation
    /// the scores stratify by word class — filler "uh," at **0.17**, the
    /// conjunction "but" at **0.43**, the content word "side" at **0.54**. So
    /// correct content words sit around 0.5+, and a floor below that only ever
    /// catches words whose confidence was never meaningful in the first place.
    private static let confidenceFloor = 0.45

    /// Never flagged, whatever they score — and never measured either.
    ///
    /// This is the real fix, not the threshold. The weakest word in an utterance
    /// is almost always filler or a function word, so a plain minimum-confidence
    /// gate reports on the words that don't matter and stays silent on the ones
    /// that do. Excluding them is what makes a threshold mean anything, and what
    /// makes the reported number worth tuning against.
    private static let ignoredForConfidence: Set<String> = [
        // Disfluencies — low confidence by nature, and no one wants them back.
        "uhh", "umm", "err", "erm", "ahh", "hmm", "mhm", "huh", "yeah", "yep",
        "nah", "okay", "oh", "eh",
        // Closed-class function words (under three letters are already dropped).
        "the", "and", "but", "for", "nor", "yet", "are", "was", "were", "that",
        "this", "these", "those", "with", "from", "they", "them", "their",
        "there", "then", "than", "have", "has", "had", "not", "its", "you",
        "your", "our", "his", "her", "she", "him", "all", "any", "can", "could",
        "would", "should", "will", "shall", "may", "might", "must", "one",
        "into", "onto", "over", "under", "about", "after", "before", "just",
        "also", "only", "very", "some", "such", "each", "both", "more", "most",
        "like", "out", "off", "now", "how", "why", "who", "what", "when",
        "where", "which", "while", "been", "being", "does", "did", "done",
        "going", "gonna", "really", "actually", "basically", "sort", "kind",
    ]

    var isListening: Bool { state == .listening }

    /// False when the framework can't transcribe on this machine at all — the
    /// cue to hide the mic affordance rather than fail on press.
    var isSupported: Bool { SpeechTranscriber.isAvailable }

    // MARK: - Live pipeline

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var engine: AVAudioEngine?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Band energies for the composer spectrograph, low → high. Empty when idle.
    @Published private(set) var levels: [Float] = []

    /// Allocated once and reused — FFT setup is not free, and it must not be
    /// built inside the audio tap.
    private let meter = AudioLevelMeter()

    /// Proper nouns harvested from chat history, fed to the recogniser as
    /// contextual bias. See `SpokenVocabulary`.
    private(set) var vocabulary: [String] = []
    private var vocabularyStamp: Date?

    private init() {}

    // MARK: - Contextual vocabulary

    /// Rebuild the bias vocabulary from chat history. Safe to call on every view
    /// appearance — it no-ops while the cache is fresh, and the harvest itself
    /// runs off the main actor.
    func refreshVocabulary(from store: ConversationStore) async {
        if let stamp = vocabularyStamp, Date().timeIntervalSince(stamp) < Self.vocabularyTTL {
            return
        }
        let records = await store.userMessageCorpus()
        guard !records.isEmpty else { return }

        // ⚠ Dictated text is excluded outright. It is the recogniser's own
        // output, and feeding it back as recognition bias is a positive feedback
        // loop on errors: measured on real history, the misheard "Nasik"
        // outnumbered the typed correction "Nashik" 3:1, so frequency ranking
        // would have entrenched the mistake. Only ground truth votes.
        let corpus = records.filter { $0.source != .dictated }.map(\.content)

        harvestCorrections(from: records)

        // Counting and name-tagging are pure and go off the main actor; the
        // dictionary pass comes back to it because NSSpellChecker is AppKit.
        let harvested = await Task.detached(priority: .utility) {
            SpokenVocabulary.harvest(from: corpus)
        }.value

        let refined = SpokenVocabulary.refine(harvested)
        let blocked = Set(suppressedTerms.map { $0.lowercased() })
        vocabulary = Self.merge(
            learned: learnedTerms,
            harvested: refined.filter { !blocked.contains($0.lowercased()) }
        )
        vocabularyStamp = Date()
    }

    /// Pull corrections out of history, from both places Yogi actually makes
    /// them: editing a flagged transcript before sending, and simply saying so
    /// in chat afterwards.
    private func harvestCorrections(from records: [ConversationStore.AuthoredMessage]) {
        var learned: [String] = []
        var suppressed: [String] = []

        for record in records {
            if record.source == .corrected, let original = record.dictationOriginal {
                let diff = SpokenVocabulary.differences(from: original, to: record.content)
                learned.append(contentsOf: diff.learned)
                suppressed.append(contentsOf: diff.suppressed)
            }
            // Stated corrections are only trustworthy from text Yogi wrote.
            guard record.source != .dictated else { continue }
            for pair in SpokenVocabulary.statedCorrections(in: record.content) {
                learned.append(pair.right)
                suppressed.append(pair.wrong)
            }
        }

        // Suppress first: a term corrected in one place shouldn't survive
        // because it was learned in another.
        suppress(suppressed)
        learn(learned.filter { term in
            !suppressed.contains { $0.lowercased() == term.lowercased() }
        })
    }

    /// History doesn't change fast enough to justify re-mining it per press.
    private static let vocabularyTTL: TimeInterval = 300

    // MARK: - Control

    /// Begin listening. Handles permission, locale reservation and asset
    /// installation on the way; all of that is why this can sit in `.preparing`.
    func start() async {
        guard state == .idle else { return }
        errorMessage = nil
        finalizedText = ""
        volatileText = ""
        uncertainWords = []
        lastMinConfidence = nil
        lastWeakestWord = nil
        isLatched = false
        setMuted(false)
        state = .preparing
        do {
            try await beginListening()
            state = .listening
        } catch {
            await teardown()
            state = .idle
            errorMessage = Self.message(for: error)
        }
    }

    /// Stop listening and drain the tail. Returns the complete transcript —
    /// results keep arriving after the mic closes, so this deliberately waits
    /// rather than returning what happened to have landed already.
    @discardableResult
    func stop() async -> Utterance {
        guard state == .listening || state == .preparing else {
            return Utterance(text: transcript, uncertain: uncertainWords)
        }
        state = .finishing

        closeAudio()
        // Ending the input sequence is what tells the analyzer no more audio is
        // coming; without it `finalizeAndFinishThroughEndOfInput` would hang.
        inputContinuation?.finish()
        inputContinuation = nil

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            errorMessage = Self.message(for: error)
        }
        await resultsTask?.value

        let result = Utterance(text: transcript, uncertain: uncertainWords)
        await teardown()
        state = .idle
        return result
    }

    /// Take everything heard so far and **keep listening**.
    ///
    /// What "send" does in voice mode: the point of latching is that the mic
    /// survives a message. Tearing the session down and rebuilding it would
    /// re-prepare the analyzer between every sentence.
    func commit() async -> Utterance {
        guard state == .listening else { return await stop() }

        // Flush anything still provisional. Without this the tail of the
        // sentence finalises *after* the snapshot and turns up at the head of
        // the next message instead.
        try? await analyzer?.finalize(through: nil)
        var waited = 0
        while !volatileText.isEmpty && waited < 8 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }

        let result = Utterance(text: transcript, uncertain: uncertainWords)
        finalizedText = ""
        volatileText = ""
        uncertainWords = []
        return result
    }

    // MARK: - Half-duplex

    /// True while Alice is talking, when the mic must be deaf.
    ///
    /// Half-duplex by design for v1: the alternative is echo cancellation via
    /// `setVoiceProcessingEnabled`, which enables true barge-in but changes the
    /// input format and so collides with the format-matching the recogniser
    /// depends on. That is its own slice.
    @Published private(set) var isMuted = false {
        didSet { muteFlag.value = isMuted }
    }

    /// Read from the realtime audio thread, so it cannot be actor-isolated.
    private let muteFlag = MuteFlag()

    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        if muted, let bands = meter?.decay() { levels = bands }
    }

    /// Abandon the utterance and discard what was heard.
    func cancel() async {
        guard state != .idle else { return }
        closeAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        await teardown()
        finalizedText = ""
        volatileText = ""
        state = .idle
    }

    // MARK: - Setup

    private func beginListening() async throws {
        guard SpeechTranscriber.isAvailable else { throw SpeechInputError.unsupportedDevice }
        try await ensureMicrophoneAccess()

        let locale = try await resolveLocale()
        let transcriber = makeTranscriber(locale: locale)
        try await prepareAssets(for: transcriber, locale: locale)
        self.transcriber = transcriber

        // The analyzer's preferred format is NOT the tap's native format; the
        // mismatch is the single most common cause of "STT is inaccurate", and
        // the framework has dedicated errors for it (`unexpectedAudioFormat`,
        // `incompatibleAudioFormats`). Passing the tap format as `naturalFormat`
        // lets it pick the cheapest compatible target.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0 else { throw SpeechInputError.noInputDevice }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: tapFormat
        ) else { throw SpeechInputError.noCompatibleAudioFormat }

        let conversion = try AudioConversion(from: tapFormat, to: analyzerFormat)

        // `.lingering` keeps the model resident between utterances — voice input
        // is bursty, and reloading per press would put a stall on every one.
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        // Bias toward words Yogi actually uses. This lives on the *analyzer*,
        // not the transcriber, which is why it works despite `ContentHint`
        // being unavailable on `SpeechTranscriber`. Set before `start` so the
        // very first utterance already benefits.
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }

        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation
        self.analyzer = analyzer
        self.engine = engine

        consumeResults(from: transcriber)

        // Realtime audio thread: convert and hand off, nothing else. No actor
        // hops, no allocation beyond the output buffer, no logging.
        // 2048 rather than 4096: the tap drives the spectrograph as well as the
        // recogniser, and 4096 frames is only ~12 updates/second — visibly
        // steppy. 2048 roughly doubles that for negligible extra cost.
        let meter = self.meter
        let muted = self.muteFlag
        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
            // Half-duplex: while Alice speaks, her voice reaches this mic
            // through the speakers. Dropping the buffer here — rather than
            // stopping the engine — keeps the session and its warm model alive
            // so listening resumes the instant she finishes.
            if muted.value {
                if let bands = meter?.decay() {
                    Task { @MainActor in self?.levels = bands }
                }
                return
            }
            // Realtime thread. The FFT is fixed-cost and allocation-free; only
            // the publish hops to the main actor.
            if let bands = meter?.bands(from: buffer) {
                Task { @MainActor in self?.levels = bands }
            }
            guard let converted = conversion.convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw SpeechInputError.engineFailed(error.localizedDescription)
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// Explicit rather than a `Preset` so the choices are legible:
    /// - `volatileResults` gives the live partial the UI shows while speaking.
    /// - `etiquetteReplacements` is deliberately OFF — it masks profanity, and
    ///   silently censoring what Yogi said into his own assistant is wrong.
    /// - `fastResults` is off: accuracy matters more than latency here, and the
    ///   volatile stream already covers responsiveness.
    /// - `transcriptionConfidence` is the error signal: it marks the words the
    ///   recogniser itself doubts, which is what lets the system ask for help
    ///   only when it needs it instead of every time.
    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.transcriptionConfidence]
        )
    }

    private func resolveLocale() async throws -> Locale {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match
        }
        // Alice's prompt is English, so an English fallback beats failing when
        // the user's region isn't itself a supported transcription locale.
        let supported = await SpeechTranscriber.supportedLocales
        if let english = supported.first(where: { $0.language.languageCode?.identifier == "en" }) {
            return english
        }
        throw SpeechInputError.noSupportedLocale
    }

    /// `AssetInventory` is a reservation model with a hard cap: a locale must be
    /// reserved before its model can be used, and the models themselves are a
    /// download. Both failure modes have dedicated errors
    /// (`assetLocaleNotAllocated`, `tooManyAssetLocalesAllocated`).
    private func prepareAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(locale) {
            try await AssetInventory.reserve(locale: locale)
        }
        guard await AssetInventory.status(forModules: [transcriber]) != .installed else { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            // First run only, and it is a real download — this is the whole
            // reason `.preparing` is a distinct state. Progress reporting is
            // available on `request.progress` when the download UX lands.
            try await request.downloadAndInstall()
        }
    }

    private func consumeResults(from transcriber: SpeechTranscriber) {
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedText = Self.appending(text, to: self.finalizedText)
                        self.volatileText = ""
                        // Only final results carry a settled judgement; volatile
                        // runs are still being revised, so their confidence
                        // would flag words the recogniser is about to fix itself.
                        self.flagLowConfidence(in: result.text)
                    } else {
                        self.volatileText = text
                    }
                }
            } catch {
                self?.errorMessage = Self.message(for: error)
            }
        }
    }

    /// Collect words the recogniser scored below the floor. Confidence is a
    /// per-run attribute, and a run can span several words, so each is split out
    /// — a whole phrase highlighted as doubtful is not actionable feedback.
    private func flagLowConfidence(in attributed: AttributedString) {
        for run in attributed.runs {
            guard let confidence = run.transcriptionConfidence else { continue }
            let span = String(attributed[run.range].characters)

            // Confidence is per-run and a run can span several words, so pull out
            // the ones actually worth judging. A run carrying only filler or
            // function words is skipped entirely — not flagged, and not counted
            // toward the reported minimum, since "uh 0.17" tells us nothing.
            let content = span
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 && !Self.ignoredForConfidence.contains($0.lowercased()) }
            guard !content.isEmpty else { continue }

            // Tracked for every eligible run, not just failing ones: without it,
            // "never flagged anything" and "the attribute is empty" look
            // identical, and a silently dead signal is the worst outcome here.
            if confidence <= (lastMinConfidence ?? .infinity) {
                lastMinConfidence = confidence
                lastWeakestWord = content.joined(separator: " ")
            }

            guard confidence < Self.confidenceFloor else { continue }
            for word in content where !uncertainWords.contains(word) {
                uncertainWords.append(word)
            }
        }
    }

    // MARK: - Learned corrections

    /// Terms Yogi corrected by hand after a flagged utterance.
    ///
    /// Persisted separately from the history harvest on purpose: a correction
    /// that lived only in the derived vocabulary would evaporate as soon as the
    /// message aged out of the corpus window. This set is the actual learned
    /// artifact — see the `direction_vocabulary_as_self_learning_seed` memory.
    func learn(_ terms: [String]) {
        guard !terms.isEmpty else { return }
        var stored = UserDefaults.standard.stringArray(forKey: Keys.learnedTerms) ?? []
        for term in terms where !stored.contains(term) { stored.append(term) }
        if stored.count > Self.learnedTermLimit {
            stored.removeFirst(stored.count - Self.learnedTermLimit)
        }
        UserDefaults.standard.set(stored, forKey: Keys.learnedTerms)
        // Apply immediately — the next utterance should already benefit rather
        // than waiting for the harvest TTL to lapse.
        let blocked = Set(suppressedTerms.map { $0.lowercased() })
        vocabulary = Self.merge(learned: stored, harvested: vocabulary)
            .filter { !blocked.contains($0.lowercased()) }
    }

    var learnedTerms: [String] {
        UserDefaults.standard.stringArray(forKey: Keys.learnedTerms) ?? []
    }

    /// Misrecognitions to keep out of the vocabulary however often they appear.
    ///
    /// Needed because the corpus can't be trusted to police itself: an error
    /// repeats every time it's misheard while its correction is stated once, so
    /// frequency ranking favours the mistake. This list is what lets a single
    /// correction beat three repetitions — and it repairs history retroactively,
    /// since corrections already in the log get re-read on every harvest.
    var suppressedTerms: [String] {
        UserDefaults.standard.stringArray(forKey: Keys.suppressedTerms) ?? []
    }

    func suppress(_ terms: [String]) {
        guard !terms.isEmpty else { return }
        var stored = suppressedTerms
        for term in terms where !stored.contains(term) { stored.append(term) }
        if stored.count > Self.learnedTermLimit {
            stored.removeFirst(stored.count - Self.learnedTermLimit)
        }
        UserDefaults.standard.set(stored, forKey: Keys.suppressedTerms)
        let blocked = Set(stored.map { $0.lowercased() })
        vocabulary = vocabulary.filter { !blocked.contains($0.lowercased()) }
    }

    /// Learned terms come first so a re-harvest can never truncate them away.
    private static func merge(learned: [String], harvested: [String]) -> [String] {
        var seen = Set<String>()
        return (learned + harvested).filter { seen.insert($0).inserted }
    }

    private static let learnedTermLimit = 300

    enum Keys {
        static let learnedTerms = "sttLearnedTerms"
        static let suppressedTerms = "sttSuppressedTerms"
    }

    // MARK: - Teardown

    private func closeAudio() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
    }

    private func teardown() async {
        closeAudio()
        meter?.reset()
        levels = []
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        engine = nil
    }

    // MARK: - Permission

    private func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw SpeechInputError.microphoneDenied
            }
        default:
            throw SpeechInputError.microphoneDenied
        }
    }

    // MARK: - Text assembly

    private static func appending(_ addition: String, to existing: String) -> String {
        let piece = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return existing }
        return existing.isEmpty ? piece : existing + " " + piece
    }

    private static func message(for error: Error) -> String {
        if let known = error as? SpeechInputError { return known.message }
        return error.localizedDescription
    }
}

// MARK: - Errors

enum SpeechInputError: Error {
    case unsupportedDevice
    case microphoneDenied
    case noInputDevice
    case noSupportedLocale
    case noCompatibleAudioFormat
    case converterUnavailable
    case engineFailed(String)

    var message: String {
        switch self {
        case .unsupportedDevice:
            return "Speech recognition isn't available on this Mac."
        case .microphoneDenied:
            return "Looking Glass needs microphone access. Grant it in System Settings → Privacy & Security → Microphone."
        case .noInputDevice:
            return "No microphone is available."
        case .noSupportedLocale:
            return "No supported transcription language is installed."
        case .noCompatibleAudioFormat:
            return "This Mac's microphone format isn't compatible with speech recognition."
        case .converterUnavailable:
            return "Couldn't convert microphone audio for speech recognition."
        case .engineFailed(let detail):
            return "Couldn't start the microphone: \(detail)"
        }
    }
}

// MARK: - Format conversion

/// A Bool the audio thread can read without actor isolation.
///
/// Same justification as `AudioConversion` below: the realtime tap callback
/// cannot hop to the main actor to ask whether it should be listening, and a
/// single Bool cannot tear.
private final class MuteFlag: @unchecked Sendable {
    var value = false
}

/// Resamples the mic tap into the analyzer's preferred format.
///
/// `@unchecked Sendable` because `AVAudioConverter` isn't `Sendable` but is only
/// ever touched inside the tap callback, which the engine serialises. It must be
/// created once and reused: the converter carries resampler state, so building
/// one per buffer would glitch at every boundary.
private final class AudioConversion: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let target: AVAudioFormat
    private let ratio: Double

    init(from source: AVAudioFormat, to target: AVAudioFormat) throws {
        self.target = target
        if source == target {
            self.converter = nil
        } else {
            guard let converter = AVAudioConverter(from: source, to: target) else {
                throw SpeechInputError.converterUnavailable
            }
            self.converter = converter
        }
        self.ratio = target.sampleRate / source.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }

        // Sample-rate conversion changes the frame count, so the output buffer
        // is sized by the rate ratio (+1 for rounding) rather than the input's.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            // The callback is asked repeatedly; hand over this buffer once and
            // then report starvation, or the converter loops forever.
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
