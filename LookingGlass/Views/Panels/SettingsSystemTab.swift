import SwiftUI
import UniformTypeIdentifiers

struct SettingsSystemTab: View {
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"
    @AppStorage("systemPrompt") private var systemPrompt = ""
    @AppStorage("enabledTools") private var enabledToolsJSON = ""
    @AppStorage("appleIntelligenceEnabled") private var appleIntelligenceEnabled = true
    @AppStorage("semanticSearchEnabled") private var semanticSearchEnabled = false
    @AppStorage(SpeechOutputService.Keys.enabled) private var voiceOutputEnabled = true
    @AppStorage(SpeechOutputService.Keys.voice) private var ttsVoiceIdentifier = ""
    @AppStorage(SpeechOutputService.Keys.rate) private var ttsRate = 0.5
    @ObservedObject private var speech = SpeechOutputService.shared
    @AppStorage("ocrPastedImages") private var ocrPastedImages = true
    @ObservedObject private var upscaler = SuperResolutionService.shared
    @AppStorage("filesRoot") private var filesRoot = ""

    /// Where independent (non-project) chats save files when no custom path is set.
    /// Mirrors the sidecar's default in agent.py — keep the two in sync.
    private var defaultFilesRoot: String {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LookingGlass").path)
            ?? "~/Documents/LookingGlass"
    }

    @State private var tools: [ToolInfo] = []
    @State private var loadingTools = true
    /// Enumerated once — the system engine vends ~180 entries across 44 locales.
    @State private var voices: [VoiceOption] = []
    @State private var promptExpanded = false
    @State private var showingPromptImporter = false

    /// Text file types accepted by the "Load from File…" importer (.txt + .md/.markdown).
    private var promptFileTypes: [UTType] {
        var t: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { t.append(md) }
        if let markdown = UTType(filenameExtension: "markdown") { t.append(markdown) }
        return t
    }

    /// Read a picked .txt/.md file into the system-prompt field. Setting `systemPrompt`
    /// (an @AppStorage) autosaves it — identical to the paste path.
    private func loadPromptFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let contents = try? String(contentsOf: url, encoding: .utf8) {
            systemPrompt = contents
            promptExpanded = true   // reveal the field so the load is visible
        }
    }

    private let client = SidecarClient()

    var body: some View {
        Form {
            personalitySection
            connectionSection
            filesSection
            appleIntelligenceSection
            voiceSection
            semanticSearchSection
            imagesSection
            toolsSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await loadTools() }
        // Free on the system engine; on a backend with a model to load this is
        // what keeps the Preview button from stalling on first press.
        .task { await speech.warmUp() }
        .onAppear { voices = speech.voices() }
        // Downloading a voice happens in System Settings, so the new one only exists
        // once we come back — re-enumerate on reactivation rather than showing a
        // stale list right after the user acted on the hint below.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            voices = speech.voices()
        }
    }

    // MARK: Voice

    private var voiceSection: some View {
        Section("Voice") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Read aloud", isOn: $voiceOutputEnabled)
                Text("Adds a speaker button to Alice's messages. On-device — nothing is sent anywhere.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if voiceOutputEnabled {
                voicePicker
                rateSlider
                previewRow
                if let hint = speech.upgradeHint {
                    upgradeHintRow(hint)
                }
            }
        }
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Voice", selection: $ttsVoiceIdentifier) {
                Text("Automatic").tag("")
                Divider()
                ForEach(voices) { voice in
                    Text(voice.label).tag(voice.id)
                }
            }
            if ttsVoiceIdentifier.isEmpty, let auto = speech.defaultVoice() {
                Text("Automatic picks the best installed voice — currently \(auto.name) (\(auto.language)).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rateSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Speaking Rate")
                Spacer()
                Text(String(format: "%.2f×", ttsRate / SpeechOutputService.naturalRate))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // The API range is 0…1 but the extremes are unusable; this band spans
            // "deliberate" to "brisk" around the system default of 0.5.
            Slider(value: $ttsRate, in: 0.35...0.65, step: 0.01)
        }
    }

    private var previewRow: some View {
        HStack {
            Button {
                SpeechOutputService.shared.toggle(Self.voiceSample, id: SpeechOutputService.previewID)
            } label: {
                Label(
                    speech.isSpeaking(SpeechOutputService.previewID) ? "Stop" : "Preview",
                    systemImage: speech.isSpeaking(SpeechOutputService.previewID)
                        ? "stop.fill" : "play.fill"
                )
            }
            Spacer()
        }
    }

    // Plain, immediately parseable prose — a preview exists to let you judge the
    // voice, not to decode the words. (The original opened on "Curiouser and
    // curiouser", which spoken cold reads as a nonsense syllable said twice.)
    private static let voiceSample =
        "This is how I'll sound when I read something back to you. "
        + "Long answers, short ones, whatever you send my way."

    /// Whatever the active engine offers as its "this could sound better"
    /// nudge — free voice downloads on the system engine, a model download on a
    /// neural one. The view doesn't know or care which.
    private func upgradeHintRow(_ hint: SpeechUpgradeHint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hint.message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Button(hint.buttonTitle) { hint.action() }
                .font(.system(size: 11))
            if let detail = hint.detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Personality

    private var personalitySection: some View {
        Section("Personality") {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { promptExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("System Prompt")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    if systemPrompt.isEmpty {
                        Text("Default")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                        Text("Custom · saved")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(promptExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if promptExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    FocusedTextEditor(
                        text: $systemPrompt,
                        font: .system(size: 12, design: .monospaced),
                        minHeight: 180,
                        placeholder: "Empty = the built-in default Alice.\nPaste, type, or “Load from File” (.txt/.md) to make Alice yours."
                    )
                    HStack {
                        Text("Auto-saves as you type. Stored locally — never in the repo.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Load from File…") { showingPromptImporter = true }
                            .font(.system(size: 11))
                            .help("Load a .txt or .md file into the prompt (autosaves).")
                        if !systemPrompt.isEmpty {
                            Button("Reset to Default") { systemPrompt = "" }
                                .font(.system(size: 11))
                        }
                    }
                    .fileImporter(isPresented: $showingPromptImporter,
                                  allowedContentTypes: promptFileTypes,
                                  allowsMultipleSelection: false,
                                  onCompletion: loadPromptFile)
                }
            }
        }
    }

    // MARK: Files

    private var filesSection: some View {
        Section("Files") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Save location")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                HStack(spacing: 8) {
                    Text(filesRoot.isEmpty ? defaultFilesRoot : filesRoot)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(filesRoot.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseFilesRoot() }
                        .font(.system(size: 11))
                    if !filesRoot.isEmpty {
                        Button("Reset") { filesRoot = "" }
                            .font(.system(size: 11))
                    }
                }

                Text("Where files Alice creates in independent chats are saved, organized by type: generated-imagery, documents, downloads. Chats inside a Project save to the project folder instead.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFilesRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: filesRoot.isEmpty ? defaultFilesRoot : filesRoot)
        if panel.runModal() == .OK, let url = panel.url {
            filesRoot = url.path
        }
    }

    // MARK: Apple Intelligence

    private var appleIntelligenceSection: some View {
        let supported = AppleIntelligenceService.shared.isSupported
        return Section("Apple Intelligence") {
            Toggle(isOn: $appleIntelligenceEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use for utilities")
                        .font(.system(size: 12, weight: .medium))
                    Text("Auto-titles new chats, summarizes memory entries, expands search queries. On-device and private.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!supported)

            if !supported {
                Text("Not available — enable Apple Intelligence in System Settings, or check that your device is supported.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Meaning-based search

    private var semanticSearchSection: some View {
        Section("History Search") {
            Toggle(isOn: $semanticSearchEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meaning-based search")
                        .font(.system(size: 12, weight: .medium))
                    Text("Experimental. Adds a “Related” section to history search that finds conversations by meaning. Currently reliable only for content-rich chats — off by default until conversation summaries improve its recall. Keyword search is unchanged. On-device via Ollama (embeddinggemma).")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Images

    private var imagesSection: some View {
        Section("Images") {
            Toggle(isOn: $ocrPastedImages) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extract text from pasted images")
                        .font(.system(size: 12, weight: .medium))
                    Text("When you paste a screenshot or document that's mostly text, read it on-device with Vision and drop the text into the input — instead of describing the image. Instant, private, no model call.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("4× image upscaler")
                            .font(.system(size: 12, weight: .medium))
                        Text("On-device RealPLKSR super-resolution — adds real detail to a generated image in the viewer (an “Upscale 4×” button appears). Downloads a ~30 MB model once.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    upscalerControl
                }
                if case .failed(let msg) = upscaler.status {
                    Text(msg).font(.system(size: 10)).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder private var upscalerControl: some View {
        switch upscaler.status {
        case .notInstalled, .failed:
            Button("Download") { Task { await upscaler.install() } }
        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        case .compiling:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .ready:
            HStack(spacing: 8) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.green)
                Button("Remove") { upscaler.remove() }.controlSize(.small)
            }
        }
    }

    // MARK: Ollama

    private var connectionSection: some View {
        Section("Ollama") {
            VStack(alignment: .leading, spacing: 6) {
                Text("API URL")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                FocusedTextField("http://host:port", text: $ollamaHost,
                                 font: .system(size: 12, design: .monospaced))
                Text("Point at a remote machine on your network to offload inference.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Tools

    @ViewBuilder
    private var toolsSection: some View {
        Section("Tools") {
            if loadingTools {
                HStack { ProgressView().scaleEffect(0.6); Text("Loading…").foregroundStyle(.secondary) }
            } else if tools.isEmpty {
                Text("No tools available (sidecar offline?)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tools) { tool in
                    toolToggle(tool)
                }
            }
        }
    }

    private func toolToggle(_ tool: ToolInfo) -> some View {
        Toggle(isOn: bindingFor(tool.name)) {
            HStack(spacing: 6) {
                Text(tool.name)
                    .font(.system(size: 12, weight: .medium))
                if tool.dangerous {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("Can modify files or run commands on your system.")
                }
            }
            .help(tool.description)
        }
    }

    // MARK: Logic

    private func loadTools() async {
        loadingTools = true
        tools = await client.fetchTools()
        loadingTools = false
        if var set = decodedSet() {
            let fresh = tools.map(\.name).filter { !set.contains($0) }
            if !fresh.isEmpty {
                set.formUnion(fresh)
                if let data = try? JSONEncoder().encode(Array(set).sorted()),
                   let json = String(data: data, encoding: .utf8) {
                    enabledToolsJSON = json
                }
            }
        }
    }

    private func bindingFor(_ name: String) -> Binding<Bool> {
        Binding(get: { isEnabled(name) }, set: { setEnabled(name, $0) })
    }

    private func decodedSet() -> Set<String>? {
        guard !enabledToolsJSON.isEmpty,
              let data = enabledToolsJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return Set(arr)
    }

    private func isEnabled(_ name: String) -> Bool {
        decodedSet()?.contains(name) ?? true
    }

    private func setEnabled(_ name: String, _ on: Bool) {
        var set = decodedSet() ?? Set(tools.map(\.name))
        if on { set.insert(name) } else { set.remove(name) }
        if let data = try? JSONEncoder().encode(Array(set).sorted()),
           let json = String(data: data, encoding: .utf8) {
            enabledToolsJSON = json
        }
    }
}
