import SwiftUI
import AppKit

struct SettingsPanel: View {
    @AppStorage("colorSchemeRaw") private var colorSchemeRaw = AppColorScheme.system.rawValue
    @AppStorage("chatFontChoice") private var chatFontChoice = ChatFontChoice.system.rawValue
    @AppStorage("fontSize") private var fontSize = 14.0
    @AppStorage("lineHeight") private var lineHeight = 1.2
    @AppStorage("backgroundStyle") private var backgroundStyle = BackgroundStyle.glass.rawValue
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"
    @AppStorage("enabledTools") private var enabledToolsJSON = ""
    @AppStorage("systemPrompt") private var systemPrompt = ""
    @AppStorage("userAvatarVersion") private var userAvatarVersion = 0

    @State private var tools: [ToolInfo] = []
    @State private var loadingTools = true
    @State private var promptExpanded = false

    private let client = SidecarClient()

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Settings", showAppIcon: true)
            Divider()
            Form {
                appearanceSection
                personalitySection
                connectionSection
                toolsSection
                profileSection
                updatesSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loadTools() }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Color Mode", selection: $colorSchemeRaw) {
                ForEach(AppColorScheme.allCases, id: \.rawValue) { scheme in
                    Text(scheme.rawValue).tag(scheme.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Picker("Background", selection: $backgroundStyle) {
                ForEach(BackgroundStyle.allCases, id: \.rawValue) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Picker("Chat Font", selection: $chatFontChoice) {
                    ForEach(ChatFontChoice.allCases) { choice in
                        Text(choice.label).font(choice.font(13)).tag(choice.rawValue)
                    }
                }
                Text("Prose & input. Code always uses the system monospace.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(fontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $fontSize, in: 11...22, step: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Line Height")
                    Spacer()
                    Text(String(format: "%.2f×", lineHeight))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $lineHeight, in: 1.0...1.5, step: 0.05)
            }
        }
    }

    // MARK: Updates (only in the shipped .app)

    @ViewBuilder
    private var updatesSection: some View {
        if AppEnvironment.isBundledApp {
            Section("Updates") {
                Picker("Check for Updates", selection: Binding(
                    get: { UpdaterService.shared.updateCheckSchedule },
                    set: { UpdaterService.shared.updateCheckSchedule = $0 }
                )) {
                    ForEach(UpdateCheckSchedule.allCases, id: \.rawValue) { schedule in
                        Text(schedule.displayName).tag(schedule)
                    }
                }
                Button("Check for Updates…") {
                    UpdaterService.shared.checkForUpdates()
                }
            }
        }
    }

    // MARK: Personality

    private var personalitySection: some View {
        Section("Personality") {
            // Collapsed header — tap to expand. Stays compact so the settings
            // pane doesn't blow up once a long prompt is pasted in.
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
                    TextEditor(text: $systemPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 180)
                        .padding(6)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topLeading) {
                            if systemPrompt.isEmpty {
                                Text("Empty = the built-in default Alice.\nPaste your own prompt to make Alice yours.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 14)
                                    .padding(.leading, 11)
                                    .allowsHitTesting(false)
                            }
                        }
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

    // MARK: Connection

    private var connectionSection: some View {
        Section("Ollama") {
            VStack(alignment: .leading, spacing: 6) {
                Text("API URL")
                    .font(.system(size: 12, weight: .medium))
                // Empty title + labelsHidden: the Form was rendering the title
                // string as a label and auto-linkifying the URL-looking text.
                TextField("", text: $ollamaHost, prompt: Text("http://localhost:11434"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity)
                Text("Point at a remote machine on your network to offload inference.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Tools

    @ViewBuilder
    private var toolsSection: some View {
        let regularTools = tools.filter { $0.category != "skills" }
        let skillsTools  = tools.filter { $0.category == "skills" }

        Section("Tools") {
            if loadingTools {
                HStack { ProgressView().scaleEffect(0.6); Text("Loading…").foregroundStyle(.secondary) }
            } else if tools.isEmpty {
                Text("No tools available (sidecar offline?)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(regularTools) { tool in
                    toolToggle(tool)
                }
            }
        }
        if !skillsTools.isEmpty {
            Section("Skills") {
                ForEach(skillsTools) { tool in
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
                        .help("Can modify files or run commands on your system. Enable only if you trust the task.")
                }
            }
            .help(tool.description)
        }
    }

    // MARK: Profile

    private var profileSection: some View {
        Section("Profile") {
            HStack(spacing: 12) {
                avatarPreview
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Avatar")
                        .font(.system(size: 12, weight: .medium))
                    Text("Shown next to your messages")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 4) {
                    Button("Choose…") { pickAvatar() }
                    if AvatarStore.userAvatar(version: userAvatarVersion) != nil {
                        Button("Remove") {
                            AvatarStore.clearUserAvatar()
                            userAvatarVersion &+= 1
                        }
                        .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 11))
            }
        }
    }

    private var avatarPreview: some View {
        Group {
            if let img = AvatarStore.userAvatar(version: userAvatarVersion) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Circle().fill(Color.accentColor)
                    .overlay(Text("Y").font(.system(size: 16, weight: .bold)).foregroundStyle(.white))
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    // MARK: Logic

    private func loadTools() async {
        loadingTools = true
        tools = await client.fetchTools()
        loadingTools = false
        // Auto-enable tools added since the user last configured toggles.
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
        Binding(
            get: { isEnabled(name) },
            set: { setEnabled(name, $0) }
        )
    }

    // nil decoded set = unconfigured = everything on
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

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if AvatarStore.saveUserAvatar(from: url) {
                userAvatarVersion &+= 1
            }
        }
    }
}
