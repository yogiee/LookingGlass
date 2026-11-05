import SwiftUI
import UniformTypeIdentifiers

/// Settings → Voice: the quality tier, the Alice voice models, and her voice clip.
///
/// Every download here is the user's action — nothing is fetched on its own. AUTO may *suggest* a better
/// tier ("QUALITY+ would fit"), but only a button press downloads it.
struct VoiceTierSettings: View {
    @ObservedObject var speech: SpeechOutputService
    @AppStorage(SpeechOutputService.Keys.tier) private var tierRaw = VoiceTier.auto.rawValue
    @AppStorage(SpeechOutputService.Keys.kokoroVoice) private var kokoroVoice = ""
    @AppStorage(SpeechOutputService.Keys.voice) private var systemVoiceID = ""
    /// Enumerated on appear and on reactivation — the system engine vends ~180 voices, and new ones only
    /// appear after the user downloads them in System Settings.
    @State private var systemVoices: [VoiceOption] = []

    @State private var message: String?
    @State private var busy: VoiceTier?
    @State private var showingClipImporter = false
    @State private var clipImportKind = ClipImportKind.clip
    @State private var engineBusy = false
    @State private var clipBusy = false

    private var selected: VoiceTier { VoiceTier(rawValue: tierRaw) ?? .auto }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Voice quality", selection: $tierRaw) {
                ForEach(VoiceTier.allCases) { tier in
                    Text(tier.label).tag(tier.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text(explanation)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // The engine QUALITY runs on is its own download; a dev build carries it and hides the row.
        if let engine = speech.neuralStatus?.engine, !engine.builtin {
            engineRow(engine)
        }
        ForEach([VoiceTier.light, .quality, .qualityPlus]) { tier in
            modelRow(tier)
        }
        // One "which voice" control, never two: whichever engine is actually speaking for LIGHT.
        if speech.effectiveTier == .light {
            if speech.lightUsesKokoro { kokoroVoicePicker } else { builtInVoicePicker }
        }
        clipRow

        if let message {
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - What's in effect, in words

    private var explanation: String {
        let effective = speech.effectiveTier
        switch selected {
        case .auto:
            guard let decision = speech.autoDecision else { return "Working out what fits…" }
            var text = "AUTO → \(decision.tier.label). \(decision.reason)"
            if let upgrade = decision.couldUpgradeTo {
                text += " \(upgrade.label) would fit — download it below to use it."
            }
            if decision.tier != effective {
                text += " Using \(effective.label) until \(decision.tier.label) is ready."
            }
            return text
        case .light:
            return speech.lightUsesKokoro
                ? VoiceTier.light.summary
                : "Using the built-in system voice until LIGHT (Kokoro, ~360 MB) is downloaded."
        case .quality, .qualityPlus:
            guard effective != selected else { return selected.summary }
            return "\(selected.label) isn't ready (\(blocker(selected))) — using LIGHT meanwhile."
        }
    }

    private func blocker(_ tier: VoiceTier) -> String {
        guard let status = speech.neuralStatus else { return "voice engine not reachable" }
        if !status.available { return status.unavailableReason ?? "voice engine unavailable" }
        if !status.reference.present { return "Alice's voice clip is missing" }
        if status.tier(tier)?.installed != true { return "not downloaded" }
        return "not ready"
    }

    // MARK: - Models

    private func modelRow(_ tier: VoiceTier) -> some View {
        let info = speech.neuralStatus?.tier(tier)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(tier.label) model")
                if let info {
                    Text(String(format: "%.2f GB download · %.1f GB while speaking%@",
                                Double(info.downloadBytes) / 1e9, info.peakGB,
                                info.engine == "coreai" ? ", on the CPU" : ""))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if tier == .light, speech.isOptimizingLight {
                        Text("Optimizing for this Mac — about 2 minutes, once per macOS version.")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if let info {
                if info.download.isWaiting {
                    Text("Waiting for the voice engine…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button("Cancel") { run(tier) { await speech.cancelDownload(tier) } }
                        .disabled(busy != nil)
                } else if info.download.isRunning {
                    ProgressView(value: info.download.fraction)
                        .frame(width: 110)
                    Text(String(format: "%.0f%%", info.download.fraction * 100))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    // Cancel keeps what's downloaded, so it's a pause as much as a stop.
                    Button("Cancel") { run(tier) { await speech.cancelDownload(tier) } }
                        .disabled(busy != nil)
                } else if info.installed {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Delete") { run(tier) { await speech.delete(tier) } }
                        .disabled(busy != nil)
                } else {
                    if let error = info.download.error {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .help(error)
                    } else if info.download.isResumable {
                        Text(String(format: "Paused at %.0f%%", info.download.fraction * 100))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Button(info.download.isResumable ? "Resume" : "Download") {
                        run(tier) { await speech.download(tier) }
                    }
                    .disabled(busy != nil)
                }
            } else {
                Text("Voice engine not reachable")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Voice engine

    private func engineRow(_ engine: NeuralVoiceStatus.Engine) -> some View {
        let download = engine.download
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice engine")
                Text(String(format: "Needed by QUALITY and QUALITY+ · %.0f MB download · %.0f MB on disk",
                            Double(engine.downloadBytes) / 1e6, Double(engine.installedBytes) / 1e6))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if download.isRunning, let phase = download.phase, phase != "downloading" {
                    Text(phase == "resolving" ? "Looking up packages…" : "Installing — under a minute…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if download.isRunning {
                ProgressView(value: download.fraction)
                    .frame(width: 110)
                Text(String(format: "%.0f%%", download.fraction * 100))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Cancel") { runEngine { await speech.cancelEngineDownload() } }
                    .disabled(engineBusy)
            } else if engine.installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Remove") { runEngine { await speech.removeEngine() } }
                    .disabled(engineBusy)
            } else {
                if let error = download.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .help(error)
                } else if download.isResumable {
                    Text(String(format: "Paused at %.0f%%", download.fraction * 100))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if engine.outdated {
                    Text("This version of the app needs an update to it.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Button(engine.outdated ? "Update" : download.isResumable ? "Resume" : "Download") {
                    runEngine { await speech.downloadEngine() }
                }
                .disabled(engineBusy)
            }
        }
    }

    private func runEngine(_ action: @escaping () async -> String?) {
        engineBusy = true
        message = nil
        Task {
            message = await action()
            engineBusy = false
        }
    }

    private func run(_ tier: VoiceTier, _ action: @escaping () async -> String?) {
        busy = tier
        message = nil
        Task {
            message = await action()
            busy = nil
        }
    }

    // MARK: - LIGHT voice

    /// Kokoro speaks with fixed voice packs — a different speaker from the cloned QUALITY voice. The blend
    /// auditioned in round 1 leads the list.
    private var kokoroVoicePicker: some View {
        Picker("LIGHT voice", selection: $kokoroVoice) {
            Text("Alice blend (default)").tag("")
            Divider()
            ForEach(speech.kokoroVoices().filter { $0.id != KokoroSpeechBackend.aliceBlend }) { voice in
                Text(voice.label).tag(voice.id)
            }
        }
    }

    /// macOS's own voice — NOT a LIGHT voice. It's what speaks until a voice model is downloaded, so it's
    /// labelled as the stand-in it is rather than as a tier's voice (the two used to contradict each other:
    /// a "LIGHT voice" picker full of system voices, beside a LIGHT row offering a Kokoro download).
    private var builtInVoicePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Built-in voice", selection: $systemVoiceID) {
                Text("Automatic").tag("")
                Divider()
                ForEach(systemVoices) { voice in
                    Text(voice.label).tag(voice.id)
                }
            }
            Text("macOS's own voice. Alice uses it until a voice model is downloaded — download LIGHT above "
                 + "for a better one that still runs on the CPU.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let hint = speech.upgradeHint {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hint.message).font(.system(size: 10)).foregroundStyle(.secondary)
                    Button(hint.buttonTitle) { hint.action() }.font(.system(size: 11))
                    if let detail = hint.detail {
                        Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .onAppear { systemVoices = speech.systemVoices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemVoices = speech.systemVoices()
        }
    }

    // MARK: - Alice's voice clip

    /// Clip and transcript are chosen separately: the transcript is optional, and a clip in another
    /// language clones better without one.
    private var clipRow: some View {
        let clip = speech.voiceClip
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Alice's voice clip")
                Spacer()
                if let clip {
                    Label(clip.transcript == nil ? "Voice only" : "With transcript",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Label("Missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            clipLine("Clip", clip.map { String(format: "%@ · %.1f s", $0.name, $0.seconds) }
                        ?? "None yet — QUALITY and QUALITY+ need one to speak.") {
                Button(clip == nil ? "Choose Clip…" : "Replace Clip…") { chooseFile(.clip) }
            }

            clipLine("Transcript (optional)", transcriptDetail(clip)) {
                if clip?.transcript != nil {
                    Button("Remove") { runClip { await speech.removeVoiceTranscript() } }
                }
                Button(clip?.transcript == nil ? "Choose Transcript…" : "Replace…") { chooseFile(.transcript) }
                    .disabled(clip == nil)
            }

            clipLine("Alice's own voice", aliceDetail(clip)) {
                Button("Use Alice's Voice") { runClip { await speech.useAliceVoice() } }
                    .disabled(clip?.isAlice == true)
                    .help("Sets her clip and its transcript together.")
            }

            Text("QUALITY and QUALITY+ clone the clip: a 24 kHz, mono, 16-bit WAV of 5–30 s. A transcript is "
                 + "optional — for an English clip, its exact words carry the speaker's delivery and accent too; "
                 + "for a clip in another language, leave it out. Choosing a new clip clears the old transcript.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(clipBusy)
        .onAppear { speech.refreshVoiceClip() }
        .fileImporter(isPresented: $showingClipImporter,
                      allowedContentTypes: clipImportKind == .clip ? [.wav] : [.plainText]) { result in
            guard case .success(let url) = result else { return }
            let kind = clipImportKind
            runClip {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return kind == .clip ? await speech.importVoiceClip(from: url)
                                     : await speech.importVoiceTranscript(from: url)
            }
        }
    }

    /// One sub-row of the clip box: what it is and what's set, with its actions on the right.
    private func clipLine<Actions: View>(_ title: String, _ detail: String,
                                         @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer()
            actions()
        }
        .padding(.leading, 12)
    }

    private func transcriptDetail(_ clip: SpeechOutputService.VoiceClip?) -> String {
        guard let clip else { return "Choose a clip first." }
        guard let transcript = clip.transcript else {
            return "None — clones the voice alone. Best for a clip in another language."
        }
        return "“\(transcript)”"
    }

    private func aliceDetail(_ clip: SpeechOutputService.VoiceClip?) -> String {
        if clip?.isAlice == true { return "In use." }
        return clip?.aliceSaved == true
            ? "Puts back her clip and transcript."
            : "Puts back her clip and transcript — a small download (under 1 MB) from GitHub."
    }

    private enum ClipImportKind { case clip, transcript }

    private func chooseFile(_ kind: ClipImportKind) {
        clipImportKind = kind
        showingClipImporter = true
    }

    private func runClip(_ action: @escaping () async -> String?) {
        clipBusy = true
        message = nil
        Task {
            message = await action()
            clipBusy = false
        }
    }
}
