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
    /// Whether the composer is armed for voice. Drives the lit state — in voice
    /// mode the mic reads as "on" even between utterances, because it is.
    var isVoiceMode: Bool
    /// A click arms or disarms voice mode; SPACE then does the capturing.
    var onToggleVoiceMode: () -> Void
    var onUtterance: (SpeechInputService.Utterance) -> Void

    @ObservedObject private var speech = SpeechInputService.shared

    /// Deduplicates the drag gesture's repeated `onChanged` calls into one press.
    @State private var pressing = false
    /// True when the mic was already live as this press began, which makes the
    /// press the closing half of a toggle rather than the opening half.
    @State private var stopWhenReleased = false
    /// Set once the press has lasted long enough to count as a hold and the mic
    /// has actually been opened.
    @State private var didStartHold = false
    @State private var holdTask: Task<Void, Never>?

    /// Under this, a press reads as a click; at or over it, as a hold. Matches
    /// `VoiceKeyMonitor` so the mic and the SPACE bar feel the same.
    private static let holdThreshold: Duration = .milliseconds(220)

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
            // Determinate whenever we know the fraction: on first use this is a
            // model download that can run for minutes, and a spinner that long
            // is indistinguishable from a hang.
            if let fraction = speech.downloadProgress {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
            }
        default:
            let lit = speech.isListening || isVoiceMode
            Image(systemName: lit ? "mic.fill" : "mic")
                .font(.system(size: 15, weight: lit ? .semibold : .regular))
                .foregroundStyle(lit ? Color.accentColor : Color.secondary.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(lit ? Color.accentColor.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
    }

    private var helpText: String {
        if isVoiceMode { return "Voice mode on — hold SPACE to talk, double-tap SPACE to stay on" }
        let base = "Click for voice mode, or hold to dictate once"
        // Exposes the raw signal so the confidence floor gets tuned against real
        // numbers. "no confidence data" here means the attribute isn't arriving.
        guard let low = speech.lastMinConfidence else { return base }
        let word = speech.lastWeakestWord.map { "\"\($0)\" " } ?? ""
        return base + String(format: " · weakest last time: %@%.2f", word, low)
    }

    // MARK: - Gesture

    private func pressDown() {
        guard !isDisabled else { return }
        didStartHold = false

        // Already capturing (latched by SPACE): this press is a stop.
        if speech.isListening {
            stopWhenReleased = true
            return
        }
        stopWhenReleased = false

        // ⚠ Deliberately does NOT open the mic yet. Starting on press and
        // cancelling on a click raced its own async setup — the cancel landed
        // mid-setup, setup finished afterwards, and the mic came back on. That
        // made arming voice mode start listening immediately and disarming
        // impossible. Waiting until the press is known to be a hold removes the
        // race rather than narrowing it.
        holdTask?.cancel()
        holdTask = Task {
            do { try await Task.sleep(for: Self.holdThreshold) } catch { return }
            didStartHold = true
            await speech.start()
        }
    }

    private func release() {
        guard !isDisabled else { return }
        holdTask?.cancel()

        if stopWhenReleased || didStartHold {
            // A released hold is a quick dictation in its own right — the path
            // for a one-off without arming voice mode at all.
            finish()
        } else {
            // Too short to be a hold, so it means the mode, not the mic.
            onToggleVoiceMode()
        }
        didStartHold = false
        stopWhenReleased = false
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
