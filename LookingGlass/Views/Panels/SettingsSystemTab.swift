import SwiftUI

struct SettingsSystemTab: View {
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"
    @AppStorage("systemPrompt") private var systemPrompt = ""
    @AppStorage("enabledTools") private var enabledToolsJSON = ""
    @AppStorage("appleIntelligenceEnabled") private var appleIntelligenceEnabled = true
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
    @State private var promptExpanded = false

    private let client = SidecarClient()

    var body: some View {
        Form {
            personalitySection
            connectionSection
            filesSection
            appleIntelligenceSection
            toolsSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await loadTools() }
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
                        placeholder: "Empty = the built-in default Alice.\nPaste your own prompt to make Alice yours."
                    )
                    HStack {
                        Text("Auto-saves as you type. Stored locally — never in the repo.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !systemPrompt.isEmpty {
                            Button("Reset to Default") { systemPrompt = "" }
                                .font(.system(size: 11))
                        }
                    }
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
