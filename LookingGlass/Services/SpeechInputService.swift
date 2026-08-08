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
        let corpus = await store.userMessageCorpus()
        guard !corpus.isEmpty else { return }
        // Counting and name-tagging are pure and go off the main actor; the
        // dictionary pass comes back to it because NSSpellChecker is AppKit.
        let harvested = await Task.detached(priority: .utility) {
            SpokenVocabulary.harvest(from: corpus)
        }.value
        vocabulary = SpokenVocabulary.refine(harvested)
        vocabularyStamp = Date()
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
    func stop() async -> String {
        guard state == .listening || state == .preparing else { return transcript }
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

        let result = transcript
        await teardown()
        state = .idle
        return result
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
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
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
    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
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
                    } else {
                        self.volatileText = text
                    }
                }
            } catch {
                self?.errorMessage = Self.message(for: error)
            }
        }
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
