import AVFoundation
import AppKit
import Foundation

/// `AVSpeechSynthesizer` behind the `SpeechBackend` protocol — the built-in
/// engine, and as of Phase 0 the only one.
///
/// Always available, nothing to download, nothing to load: `readiness` is
/// permanently `.ready` and `prepare()` does nothing. The interesting parts of
/// the protocol are all inert here, which is the point — they exist for the
/// engine that comes next.
///
/// Voice-tier findings (measured, see `feature_tts_read_aloud`): enhanced and
/// premium voices are free but user-downloaded, so the picker must never filter
/// to them or it comes up empty on a stock Mac. That policy lives in `voices()`.
@MainActor
final class SystemSpeechBackend: NSObject, SpeechBackend {
    let id: SpeechBackendID = .system

    private let synthesizer = AVSpeechSynthesizer()

    /// Callbacks for utterances still in flight, keyed by identity.
    ///
    /// Keyed rather than single-valued because replacing an utterance cancels
    /// the old one, and the resulting `didCancel` arrives *after* the
    /// replacement has already been registered. Identity keying stops a late
    /// cancellation from resolving the utterance that replaced it.
    private var pending: [ObjectIdentifier: Callbacks] = [:]

    private struct Callbacks {
        let onStart: @MainActor () -> Void
        let onFinish: @MainActor () -> Void
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Readiness

    var readiness: SpeechReadiness { .ready }

    /// Nothing to warm — the system engine is resident in the OS.
    func prepare() async {}

    // MARK: - Speaking

    func speak(
        _ text: String,
        voiceID: String?,
        rate: Double,
        onStart: @escaping @MainActor () -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // Resolve the outgoing utterance's callbacks synchronously rather than
        // trusting the cancellation delegate to arrive: `onFinish` is
        // contractually exactly-once, and flushing here makes that true even if
        // the callback never comes.
        flushPending()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolveVoice(voiceID)
        utterance.rate = Self.avRate(fromMultiple: rate)
        pending[ObjectIdentifier(utterance)] = Callbacks(onStart: onStart, onFinish: onFinish)
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        flushPending()
    }

    /// Resolve every outstanding utterance exactly once and forget it, so a
    /// delegate callback arriving afterwards is a no-op.
    private func flushPending() {
        let outstanding = pending.values
        pending.removeAll()
        for callbacks in outstanding { callbacks.onFinish() }
    }

    // MARK: - Rate

    /// The protocol speaks in multiples of natural pace; AVFoundation uses an
    /// absolute 0…1 scale where 0.5 is normal. Convert, and clamp so an odd
    /// stored value can't produce an unusable utterance.
    private static func avRate(fromMultiple multiple: Double) -> Float {
        let raw = Float(multiple) * AVSpeechUtteranceDefaultSpeechRate
        return min(max(raw, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    // MARK: - Voices

    /// Legacy MacinTalk novelty voices — Zarvox, Bubbles, Bad News, Boing and
    /// friends. Real synthesisers live under `com.apple.voice.*`; these are the
    /// 1990s joke set and would be noise in a picker.
    private static let noveltyPrefix = "com.apple.speech.synthesis.voice."

    /// English only — Alice's prompt is English, and the unfiltered list is ~180
    /// entries across 44 locales. Ordered best quality first.
    ///
    /// Deliberately *not* filtered to enhanced/premium: those tiers are
    /// user-downloads, so filtering yields an empty picker on a stock Mac.
    func voices() -> [VoiceOption] {
        Self.systemVoices().map(Self.option)
    }

    private static func systemVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { !$0.identifier.hasPrefix(noveltyPrefix) }
            .sorted {
                if $0.quality.rawValue != $1.quality.rawValue {
                    return $0.quality.rawValue > $1.quality.rawValue
                }
                if $0.language != $1.language { return $0.language < $1.language }
                return $0.name < $1.name
            }
    }

    private static func option(_ voice: AVSpeechSynthesisVoice) -> VoiceOption {
        VoiceOption(
            id: voice.identifier,
            name: voice.name,
            quality: qualityLabel(voice.quality),
            language: voice.language
        )
    }

    /// Highest quality installed, tie-broken toward the user's own region and
    /// then toward Samantha — the most neutral voice on a stock install.
    func defaultVoice() -> VoiceOption? {
        Self.bestAvailableVoice().map(Self.option)
    }

    private static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let region = Locale.current.region?.identifier
        return systemVoices().max { a, b in rank(a, region) < rank(b, region) }
    }

    private static func rank(_ v: AVSpeechSynthesisVoice, _ region: String?) -> (Int, Int, Int) {
        let regionMatch = (region.map { v.language.hasSuffix("-\($0)") } ?? false) ? 1 : 0
        let neutral = v.name == "Samantha" ? 1 : 0
        return (v.quality.rawValue, regionMatch, neutral)
    }

    /// A stored pick can vanish when the user removes the voice in System
    /// Settings, so `AVSpeechSynthesisVoice(identifier:)` is optional and we
    /// always have a fallback. nil hands the choice to AVFoundation.
    private func resolveVoice(_ voiceID: String?) -> AVSpeechSynthesisVoice? {
        if let voiceID, !voiceID.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            return voice
        }
        return Self.bestAvailableVoice()
    }

    static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        case .default:  return "Compact"
        @unknown default: return "Standard"
        }
    }

    // MARK: - Upgrade hint

    /// Offered only when nothing better than compact is installed. This is the
    /// single biggest quality lever the system engine has, and it costs the user
    /// one download.
    var upgradeHint: SpeechUpgradeHint? {
        guard onlyDefaultQualityInstalled else { return nil }
        return SpeechUpgradeHint(
            message: "Only compact voices are installed. Enhanced and Premium voices are a free download and sound dramatically more natural.",
            buttonTitle: "Get Better Voices…",
            detail: "System Settings → Accessibility → Spoken Content → System Voice → Manage Voices",
            action: Self.openVoiceDownloads
        )
    }

    private var onlyDefaultQualityInstalled: Bool {
        let voices = Self.systemVoices()
        return !voices.isEmpty && voices.allSatisfy { $0.quality == .default }
    }

    /// Open System Settings where enhanced/premium voices are downloaded.
    private static func openVoiceDownloads() {
        let panes = [
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
            "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent",
        ]
        for pane in panes {
            if let url = URL(string: pane), NSWorkspace.shared.open(url) { return }
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SystemSpeechBackend: AVSpeechSynthesizerDelegate {
    // AVFoundation calls these off the main actor; hop before touching state.
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.pending[ObjectIdentifier(utterance)]?.onStart() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.resolve(utterance) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.resolve(utterance) }
    }

    /// Fire this utterance's completion if it hasn't already been flushed.
    private func resolve(_ utterance: AVSpeechUtterance) {
        guard let callbacks = pending.removeValue(forKey: ObjectIdentifier(utterance)) else { return }
        callbacks.onFinish()
    }
}
