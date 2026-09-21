import AVFoundation
import Foundation

/// Alice's own voice — Qwen3-TTS in the sidecar, cloned from her reference clip — behind `SpeechBackend`.
///
/// The sidecar streams little-endian int16 mono PCM; this plays it through `AVAudioEngine` as it arrives.
/// First audio lands ~0.25–0.4 s after the request on a warm model (measured 2026-09-21).
///
/// **Rate is a playback property here, not a synthesis one.** Qwen3-TTS has no speed control
/// (`generate(speed=)` is accepted and ignored), so the user's rate is applied by `AVAudioUnitTimePitch`,
/// which changes tempo without changing pitch — validated against a ground-truth signal at 0.7–1.3×, the
/// whole Settings range. Because it's a live node parameter, `setRate` takes effect mid-sentence, which is
/// what the report viewer's slider needs.
@MainActor
final class NeuralSpeechBackend: SpeechBackend {
    let id: SpeechBackendID = .neural
    let tier: VoiceTier

    /// The sidecar's last word on installs, loads and the reference clip. Pushed in by
    /// `SpeechOutputService`, which owns polling; this type never fetches it itself.
    var status: NeuralVoiceStatus?

    private let client: NeuralVoiceClient
    /// Speaks instead when the neural stream fails before any audio (sidecar restarted, tier deleted
    /// under us). Reading something is better than a silent button.
    private let fallback: SpeechBackend
    private let player: StreamingVoicePlayer

    private var task: Task<Void, Never>?
    private var pendingFinish: (@MainActor () -> Void)?

    init(tier: VoiceTier, client: NeuralVoiceClient, fallback: SpeechBackend, player: StreamingVoicePlayer) {
        precondition(tier.sidecarID != nil, "NeuralSpeechBackend needs a neural tier")
        self.tier = tier
        self.client = client
        self.fallback = fallback
        self.player = player
    }

    // MARK: - Readiness

    var readiness: SpeechReadiness {
        guard let status else { return .unavailable(reason: "The voice engine isn't reachable.") }
        guard status.available else {
            return .unavailable(reason: status.unavailableReason ?? "The voice engine can't run here.")
        }
        guard status.reference.present else {
            return .unavailable(reason: "Alice's voice clip is missing.")
        }
        guard let info = status.tier(tier) else { return .unavailable(reason: "Unknown voice tier.") }
        guard info.installed else { return .needsDownload(megabytes: info.downloadBytes / 1_000_000) }
        return status.loadedTier == tier.sidecarID ? .ready : .needsWarmUp
    }

    func prepare() async {
        guard readiness.canSpeak else { return }
        await client.prepare(tier)
    }

    // MARK: - Voices

    /// One voice: Alice. The tier is the choice, not a speaker list.
    func voices() -> [VoiceOption] {
        [VoiceOption(id: "alice", name: "Alice", quality: tier.label, language: "")]
    }

    func defaultVoice() -> VoiceOption? { voices().first }

    var upgradeHint: SpeechUpgradeHint? { nil }

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
        let client = self.client
        let tier = self.tier

        task = Task { [weak self] in
            guard let self else { return }
            // Declared outside the do: a failure AFTER audio has started must not re-read the whole text
            // from the top in another voice — it just ends.
            var started = false
            do {
                let (bytes, sampleRate) = try await client.speak(text, tier: tier)
                // A newer speak() may have cancelled us while we waited for the sidecar. Check before
                // touching the player it now owns — begin() would reset it out from under the new request.
                try Task.checkCancellation()
                try self.player.begin(sampleRate: sampleRate, rate: rate, onDrained: { [weak self] in
                    self?.finishPending()
                })
                try await Self.pump(bytes) { [weak self] samples in
                    guard let self, !Task.isCancelled else { return }
                    self.player.enqueue(samples)
                    if !started {
                        started = true
                        onStart()
                    }
                }
                guard !Task.isCancelled else { return }
                if started {
                    self.player.endOfStream()          // finishes via onDrained once playback catches up
                } else {
                    self.finishPending()               // the sidecar had nothing to say
                }
            } catch {
                // stop() or a newer speak() cancelled us and already resolved the callbacks.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.player.stop()
                guard !started else {
                    print("[tts] neural stream broke mid-reading: \(error.localizedDescription)")
                    self.finishPending()
                    return
                }
                print("[tts] neural voice failed before audio: \(error.localizedDescription) — using the system voice")
                // Hand the SAME callbacks to the fallback: onFinish stays exactly-once, because we clear
                // ours first and the fallback owns it from here.
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

    private func cancelInFlight() {
        task?.cancel()
        task = nil
        player.stop()
        finishPending()
    }

    /// Resolve the outstanding utterance exactly once.
    private func finishPending() {
        let finish = pendingFinish
        pendingFinish = nil
        finish?()
    }

    // MARK: - Stream decoding

    /// ~0.25 s per scheduled buffer: small enough that audio starts promptly, large enough that the
    /// player isn't juggling hundreds of tiny buffers on a long report.
    private nonisolated static let samplesPerBuffer = 6_000

    /// Read int16 PCM off the network and hand Float32 buffers to `deliver` on the main actor.
    ///
    /// `nonisolated async`, so the byte loop runs on the generic executor, OFF the main actor (SE-0338):
    /// `AsyncBytes` yields one byte at a time, and at ~3× real time that is ~150k iterations a second —
    /// trivial in the background, janky on the UI thread. Only finished buffers (~4 a second) hop to main.
    ///
    /// Deliberately NOT `Task.detached`: a detached task doesn't inherit cancellation, so Stop would
    /// cancel the caller while the reader kept pulling the stream — and the sidecar would keep voicing the
    /// rest of a long report into the void. Staying in the caller's task means cancelling it tears down
    /// the request, the sidecar sees the disconnect, and synthesis stops within one codec chunk.
    private nonisolated static func pump(
        _ bytes: URLSession.AsyncBytes,
        deliver: @escaping @MainActor ([Float]) -> Void
    ) async throws {
        var raw = [UInt8]()
        raw.reserveCapacity(samplesPerBuffer * 2)
        for try await byte in bytes {
            raw.append(byte)
            if raw.count >= samplesPerBuffer * 2 {
                let samples = convert(raw)
                raw.removeAll(keepingCapacity: true)
                await deliver(samples)
                try Task.checkCancellation()
            }
        }
        if raw.count >= 2 {
            await deliver(convert(raw))
        }
    }

    /// Little-endian int16 → Float32 in −1…1. A trailing odd byte (never expected) is dropped.
    private nonisolated static func convert(_ raw: [UInt8]) -> [Float] {
        let count = raw.count / 2
        var out = [Float](repeating: 0, count: count)
        raw.withUnsafeBytes { buffer in
            for i in 0..<count {
                let value = Int16(littleEndian: buffer.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out[i] = Float(value) / 32_768
            }
        }
        return out
    }
}

/// Plays a PCM stream as it arrives, through a live tempo control.
///
/// Graph: `AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixer`. The engine runs only while something
/// is playing, so an idle app isn't holding the output device open.
///
/// Uses the macOS 27 throwing APIs (`connectNode`, `playAudio`): `connect(_:to:format:)` and `play()`
/// are deprecated there, and 27 is the app's floor.
@MainActor
final class StreamingVoicePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var format: AVAudioFormat?

    /// Bumped on every begin/stop so completion callbacks from a superseded stream are ignored —
    /// `stop()` itself fires the completion handler of every buffer it discards.
    private var generation = 0
    private var outstanding = 0
    private var streamEnded = false
    private var onDrained: (@MainActor () -> Void)?

    init() {
        engine.attach(node)
        engine.attach(timePitch)
    }

    /// Output level, 0…1. For ducking under other audio later — and lets a test drive the real graph
    /// without making a sound.
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = min(max(newValue, 0), 1) }
    }

    /// Tempo as a multiple of natural pace. Live: applies to audio already playing.
    var rate: Double {
        get { Double(timePitch.rate) }
        set { timePitch.rate = Float(min(max(newValue, 0.5), 2.0)) }
    }

    func begin(sampleRate: Double, rate: Double, onDrained: @escaping @MainActor () -> Void) throws {
        stop()
        if format?.sampleRate != sampleRate {
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                          channels: 1, interleaved: false) else {
                throw NeuralVoiceError(code: "format", message: "Unsupported sample rate \(sampleRate).")
            }
            if engine.isRunning { engine.stop() }
            try engine.connectNode(node, to: timePitch, format: fmt)
            try engine.connectNode(timePitch, to: engine.mainMixerNode, format: fmt)
            format = fmt
        }
        self.rate = rate
        self.onDrained = onDrained
        streamEnded = false
        outstanding = 0
        if !engine.isRunning { try engine.start() }
    }

    func enqueue(_ samples: [Float]) {
        guard let format, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        outstanding += 1
        let generation = self.generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(generation) }
        }
        if !node.isPlaying {
            do { try node.playAudio() } catch { print("[tts] player failed to start: \(error)") }
        }
    }

    /// No more audio is coming. `onDrained` fires once what's scheduled has been heard.
    func endOfStream() {
        streamEnded = true
        drainIfDone()
    }

    func stop() {
        generation += 1
        onDrained = nil
        outstanding = 0
        streamEnded = false
        node.stop()
        if engine.isRunning { engine.stop() }
    }

    private func bufferPlayed(_ generation: Int) {
        guard generation == self.generation else { return }
        outstanding -= 1
        drainIfDone()
    }

    private func drainIfDone() {
        guard streamEnded, outstanding <= 0 else { return }
        let done = onDrained
        onDrained = nil
        node.stop()
        if engine.isRunning { engine.stop() }
        done?()
    }
}
