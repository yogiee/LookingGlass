import SwiftUI

/// Voice input control — one button, two gestures.
///
/// A quick click toggles listening on and the next click stops it; a press and
/// hold listens only while held. Both work from the same button because
/// listening starts on *press-down* either way, and the **release** decides
/// which gesture it was: let go quickly and the mic stays live (click), hold
/// past the threshold and releasing stops it (push-to-talk).
///
/// Stopping hands the transcript to `onTranscript`, which sends it. An empty
/// transcript is dropped rather than sent — pressing the mic and saying nothing
/// should be a no-op, not a blank turn.
struct MicButton: View {
    var isDisabled: Bool
    var onUtterance: (SpeechInputService.Utterance) -> Void

    @ObservedObject private var speech = SpeechInputService.shared

    /// Deduplicates the drag gesture's repeated `onChanged` calls into one press.
    @State private var pressing = false
    @State private var pressStart: Date?
    /// True when the mic was already live as this press began, which makes the
    /// press the closing half of a toggle rather than the opening half.
    @State private var stopWhenReleased = false

    /// Under this, a press reads as a click; at or over it, as a hold.
    private static let holdThreshold: TimeInterval = 0.35

    var body: some View {
        // Hidden entirely when the framework can't transcribe here, rather than
        // offered and then failing on press.
        if speech.isSupported {
            control
                .opacity(isDisabled ? 0.45 : 1)
                .help(helpText)
                // A plain Button can't see press-down, and `.disabled` doesn't
                // stop a gesture — hence the manual guards in the handlers.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !pressing else { return }
                            pressing = true
                            pressDown()
                        }
                        .onEnded { _ in
                            pressing = false
                            release()
                        }
                )
        }
    }

    @ViewBuilder
    private var control: some View {
        switch speech.state {
        case .preparing, .finishing:
            // First run can sit here for a while — the language model is a real
            // download, not just a warm-up.
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
        default:
            Image(systemName: speech.isListening ? "mic.fill" : "mic")
                .font(.system(size: 15, weight: speech.isListening ? .semibold : .regular))
                .foregroundStyle(speech.isListening ? Color.accentColor : Color.secondary.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(speech.isListening ? Color.accentColor.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
    }

    private var helpText: String {
        if speech.isListening { return "Stop listening and send" }
        let base = "Click to dictate, or hold to talk"
        // Exposes the raw signal so the confidence floor gets tuned against real
        // numbers. "no confidence data" here means the attribute isn't arriving.
        guard let low = speech.lastMinConfidence else { return base }
        let word = speech.lastWeakestWord.map { "\"\($0)\" " } ?? ""
        return base + String(format: " · weakest last time: %@%.2f", word, low)
    }

    // MARK: - Gesture

    private func pressDown() {
        guard !isDisabled else { return }
        pressStart = Date()
        if speech.isListening {
            stopWhenReleased = true
        } else {
            stopWhenReleased = false
            Task { await speech.start() }
        }
    }

    private func release() {
        guard !isDisabled, let start = pressStart else { return }
        pressStart = nil
        let heldLongEnough = Date().timeIntervalSince(start) >= Self.holdThreshold
        // A quick click that *started* listening leaves the mic open; anything
        // else — a click while live, or a released hold — closes it.
        guard stopWhenReleased || heldLongEnough else {
            // Staying open *is* the latch: this press was a click, so the
            // composer is now in voice mode proper rather than a held aside.
            speech.markLatched()
            return
        }
        finish()
    }

    private func finish() {
        Task {
            let utterance = await speech.stop()
            let trimmed = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onUtterance(
                SpeechInputService.Utterance(text: trimmed, uncertain: utterance.uncertain)
            )
        }
    }
}

/// Live feedback while the mic is open — sits above the composer like the OCR
/// strip. Shows the running transcript so a misrecognition is visible before it
/// is sent, and surfaces permission or asset errors in the same place.
struct ListeningStrip: View {
    @ObservedObject private var speech = SpeechInputService.shared

    var body: some View {
        HStack(spacing: 7) {
            if let error = speech.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: speech.isListening)
                Text(label)
                    .font(.system(size: 11))
                    // The volatile tail is a guess the recogniser may revise, so
                    // the whole line stays visually provisional.
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: String {
        let text = speech.transcript
        if !text.isEmpty { return text }
        return speech.state == .preparing ? "Getting ready…" : "Listening…"
    }
}
