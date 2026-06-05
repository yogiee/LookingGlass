import SwiftUI

struct SettingsSystemTab: View {
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"
    @AppStorage("systemPrompt") private var systemPrompt = ""
    @AppStorage("enabledTools") private var enabledToolsJSON = ""

    @State private var tools: [ToolInfo] = []
    @State private var loadingTools = true
    @State private var promptExpanded = false

    private let client = SidecarClient()

    var body: some View {
        Form {
            personalitySection
            connectionSection
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

    // MARK: Ollama

    private var connectionSection: some View {
        Section("Ollama") {
            VStack(alignment: .leading, spacing: 6) {
                Text("API URL")
                    .font(.system(size: 12, weight: .medium))
                FocusedTextField("http://localhost:11434", text: $ollamaHost,
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
