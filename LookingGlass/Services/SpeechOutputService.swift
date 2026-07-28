import AVFoundation
import AppKit
import Foundation

/// Alice's spoken voice — on-device text-to-speech.
///
/// Tier-1 utility on the `AppleIntelligenceService` pattern: availability-guarded,
/// silent fallback, callers never have to know whether speech is possible. Nothing
/// here touches the sidecar — speech is purely a client-side surface, so no agent,
/// tool or SSE contract changes.
///
/// Sprint 3A is manual read-aloud only. The streaming/auto-speak path (voice mode)
/// lands next and will reuse `speak` with sentence-sized chunks.
@MainActor
final class SpeechOutputService: NSObject, ObservableObject {
    static let shared = SpeechOutputService()

    /// What's being spoken right now — a message id, or `previewID` for the
    /// Settings sample. nil means silent. Drives the play/stop button state.
    @Published private(set) var speakingID: String?

    /// Synthetic id for the Settings voice preview.
    static let previewID = "voice-preview"

    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance we believe is live. Guards against a late `didCancel` for a
    /// replaced utterance clearing the state of the one that replaced it.
    private var current: AVSpeechUtterance?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Settings

    /// User toggle. Default true — speech is opt-out, like Apple Intelligence.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.enabled).map { ($0 as? Bool) ?? true } ?? true
    }

    private var rate: Float {
        let stored = UserDefaults.standard.double(forKey: Keys.rate)
        guard stored > 0 else { return AVSpeechUtteranceDefaultSpeechRate }
        return Float(stored)
    }

    enum Keys {
        static let enabled = "voiceOutputEnabled"
        static let voice   = "ttsVoiceIdentifier"
        static let rate    = "ttsRate"
    }

    // MARK: - Speaking

    func isSpeaking(_ id: String) -> Bool { speakingID == id }

    /// Play/stop the same message; start fresh if something else is speaking.
    func toggle(_ markdown: String, id: String) {
        if speakingID == id { stop() } else { speak(markdown, id: id) }
    }

    /// Speak `markdown` aloud, cancelling anything already in flight.
    /// No-ops when the message reduces to nothing speakable (e.g. pure code).
    func speak(_ markdown: String, id: String) {
        let text = SpeechText.make(from: markdown)
        guard !text.isEmpty else { return }

        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.resolvedVoice()
        utterance.rate = rate
        current = utterance
        speakingID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        current = nil
        speakingID = nil
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Clear published state only if the finished utterance is still the live one.
    private func finished(_ utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        current = nil
        speakingID = nil
    }

    // MARK: - Voices

    /// Legacy MacinTalk novelty voices — Zarvox, Bubbles, Bad News, Boing and
    /// friends. Real synthesisers live under `com.apple.voice.*`; these are the
    /// 1990s joke set and would be noise in a picker.
    private static let noveltyPrefix = "com.apple.speech.synthesis.voice."

    /// Voices worth offering, best quality first. English only — Alice's prompt is
    /// English, and the full list is 180 entries across 44 locales.
    static func selectableVoices() -> [AVSpeechSynthesisVoice] {
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

    /// True when nothing better than compact quality is installed — the cue to
    /// point the user at Spoken Content, where enhanced/premium voices download free.
    static var onlyDefaultQualityInstalled: Bool {
        let voices = selectableVoices()
        return !voices.isEmpty && voices.allSatisfy { $0.quality == .default }
    }

    /// The user's pick, or the best automatic choice. nil hands the decision to
    /// AVFoundation (system default voice).
    static func resolvedVoice() -> AVSpeechSynthesisVoice? {
        let stored = UserDefaults.standard.string(forKey: Keys.voice) ?? ""
        // A stored voice can vanish if the user removes it in System Settings.
        if !stored.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: stored) {
            return voice
        }
        return bestAvailableVoice()
    }

    /// Highest quality installed, tie-broken toward the user's own region and then
    /// toward Samantha — the most neutral voice present on a stock install.
    static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let region = Locale.current.region?.identifier
        return selectableVoices().max { a, b in rank(a, region) < rank(b, region) }
    }

    private static func rank(_ v: AVSpeechSynthesisVoice, _ region: String?) -> (Int, Int, Int) {
        let regionMatch = (region.map { v.language.hasSuffix("-\($0)") } ?? false) ? 1 : 0
        let neutral = v.name == "Samantha" ? 1 : 0
        return (v.quality.rawValue, regionMatch, neutral)
    }

    static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        case .default:  return "Compact"
        @unknown default: return "Standard"
        }
    }

    /// Open System Settings where enhanced/premium voices are downloaded.
    static func openVoiceDownloads() {
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

extension SpeechOutputService: AVSpeechSynthesizerDelegate {
    // AVFoundation calls these off the main actor; hop before touching state.
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.finished(utterance) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.finished(utterance) }
    }
}
