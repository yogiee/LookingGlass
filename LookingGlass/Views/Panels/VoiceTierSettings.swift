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
                if info.download.isRunning {
                    ProgressView(value: info.download.fraction)
                        .frame(width: 110)
                    Text(String(format: "%.0f%%", info.download.fraction * 100))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else if info.installed {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Delete") { run(tier) { await speech.delete(tier) } }
                        .disabled(busy != nil)
                } else {
                    if let error = info.download.error {
                        Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
                    }
                    Button("Download") { run(tier) { await speech.download(tier) } }
                        .disabled(busy != nil)
                }
            } else {
                Text("Voice engine not reachable")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
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

    private var clipRow: some View {
        let present = speech.neuralStatus?.reference.present ?? false
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Alice's voice clip")
                Spacer()
                if present {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Label("Missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Button(present ? "Replace…" : "Choose…") { showingClipImporter = true }
            }
            Text("QUALITY and QUALITY+ clone this clip. A 24 kHz mono WAV, with its exact transcript beside it "
                 + "as a .txt of the same name — the two must match word for word.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $showingClipImporter, allowedContentTypes: [.wav]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                message = await speech.importVoiceClip(from: url)
            }
        }
    }
}
