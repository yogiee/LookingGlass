import SwiftUI

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isStreaming = false
    @Published var inputText = ""

    // Research mode state
    @Published var researchMode = false          // user toggle — resets after each send
    @Published var isResearching = false         // active research run in progress
    @Published var researchStatus: String? = nil // current phase label
    @Published var researchReportPath: String? = nil // set when report is saved

    private var researchSearchCount = 0
    private var researchReadCount = 0

    /// The conversation currently mirrored in `messages`. Kept in sync with the
    /// store's `activeConversationID`; `nil` = an unsaved fresh chat.
    private(set) var loadedConversationID: UUID?

    var toolCallStore: ToolCallStore?

    private let client = SidecarClient()
    private var streamTask: Task<Void, Never>?

    /// Swap the chat pane to a different conversation (or a blank one for `nil`).
    func load(_ conversationID: UUID?, store: ConversationStore) {
        streamTask?.cancel()
        isStreaming = false
        loadedConversationID = conversationID
        messages = conversationID.map { store.loadMessages($0) } ?? []
        // Restore the report path if a file_write tool call was saved and the file still exists.
        researchReportPath = messages
            .flatMap(\.toolCalls)
            .filter { $0.tool == "file_write" && $0.isComplete }
            .compactMap { Self.extractResearchPath(from: $0.result) }
            .last(where: { FileManager.default.fileExists(atPath: $0) })
        researchStatus = researchReportPath != nil ? "Report ready" : nil
    }

    func send(model: String?, ollamaHost: String, enabledTools: [String]?, systemPrompt: String?, userName: String?, mcpHintsEnabled: [String: Bool]? = nil, researchMode: Bool = false, store: ConversationStore, attachmentPath: String? = nil) {
        let typed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if let path = attachmentPath {
            text = typed.isEmpty ? "[Image: \(path)]" : "[Image: \(path)]\n\n\(typed)"
        } else {
            text = typed
        }
        guard !text.isEmpty, !isStreaming else { return }

        inputText = ""
        let userMessage = Message(role: .user, content: text)
        messages.append(userMessage)

        // Ensure a persisted conversation exists, then save the user's turn.
        // Setting loadedConversationID *before* activeConversationID means the
        // view's onChange guard treats this as "already loaded" and won't reload.
        let conversationID: UUID
        let isFirstTurn: Bool
        if let active = loadedConversationID {
            conversationID = active
            isFirstTurn = false
        } else {
            let newID = store.createConversation(title: Self.deriveTitle(text))
            loadedConversationID = newID
            store.activeConversationID = newID
            conversationID = newID
            isFirstTurn = true
        }
        store.appendMessage(userMessage, to: conversationID)

        runTurn(history: Array(messages), model: model, ollamaHost: ollamaHost,
                enabledTools: enabledTools, systemPrompt: systemPrompt, userName: userName,
                mcpHintsEnabled: mcpHintsEnabled, researchMode: researchMode, specialistMode: false,
                conversationID: conversationID, isFirstTurn: isFirstTurn, titleSeed: text, store: store)
    }

    /// "Consult the big model": re-run the last user turn on the specialist (cloud)
    /// model and append a new, cloud-tagged assistant turn. The local answer is kept
    /// above it — a labeled local↔cloud pair on the same prompt. Consent = the tap;
    /// nothing leaves the machine until the user invokes this.
    func escalate(ollamaHost: String, enabledTools: [String]?, systemPrompt: String?,
                  userName: String?, mcpHintsEnabled: [String: Bool]? = nil,
                  store: ConversationStore) {
        guard !isStreaming else { return }
        guard let conversationID = loadedConversationID else { return }
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        // History through the last USER message — exclude the local answer so the
        // specialist responds to the question fresh, not to Alice's take.
        let history = Array(messages.prefix(through: lastUserIdx))
        let seed = messages[lastUserIdx].content
        runTurn(history: history, model: nil, ollamaHost: ollamaHost,
                enabledTools: enabledTools, systemPrompt: systemPrompt, userName: userName,
                mcpHintsEnabled: mcpHintsEnabled, researchMode: false, specialistMode: true,
                conversationID: conversationID, isFirstTurn: false, titleSeed: seed, store: store)
    }

    /// Append a streaming assistant placeholder, stream the turn from the sidecar, and
    /// persist it. Shared by `send` (fresh user turn) and `escalate` (specialist re-run).
    private func runTurn(history: [Message], model: String?, ollamaHost: String,
                         enabledTools: [String]?, systemPrompt: String?, userName: String?,
                         mcpHintsEnabled: [String: Bool]?, researchMode: Bool, specialistMode: Bool,
                         conversationID: UUID, isFirstTurn: Bool, titleSeed: String,
                         store: ConversationStore) {
        messages.append(Message(role: .assistant, content: "", isStreaming: true))
        isStreaming = true

        // Research state — reset per-run so each run starts clean
        isResearching = researchMode
        researchStatus = researchMode ? "Starting research..." : nil
        researchReportPath = nil
        researchSearchCount = 0
        researchReadCount = 0
        self.researchMode = false  // reset toggle; user re-enables for next run

        // Where this conversation lives — sent so the sidecar scopes tools and
        // reads project.toml/guidelines.md. nil for independent chats.
        let projectDir = store.projectFolderPath(forConversation: conversationID)

        streamTask = Task {
            defer {
                if let idx = messages.indices.last { messages[idx].isStreaming = false }
                isStreaming = false
                isResearching = false
                if researchReportPath == nil { researchStatus = nil }
                // Persist the completed assistant turn (content + any tool calls).
                if let idx = messages.indices.last {
                    let assistant = messages[idx]
                    if !assistant.content.isEmpty || !assistant.toolCalls.isEmpty {
                        store.appendMessage(assistant, to: conversationID)
                    }
                }
            }
            do {
                for try await event in client.stream(
                    messages: history,
                    model: model,
                    ollamaHost: ollamaHost,
                    enabledTools: enabledTools,
                    systemPrompt: systemPrompt,
                    projectDir: projectDir,
                    userName: userName,
                    mcpHintsEnabled: mcpHintsEnabled,
                    researchMode: researchMode,
                    specialistMode: specialistMode
                ) {
                    guard !Task.isCancelled else { break }
                    apply(event)
                }
                // After the first assistant reply, replace the derived title with an
                // FM-generated one — more descriptive than the raw first line of user input.
                if isFirstTurn, !Task.isCancelled,
                   let assistantContent = messages.last.map({ $0.role == .assistant ? $0.content : "" }),
                   !assistantContent.isEmpty {
                    if let fmTitle = await AppleIntelligenceService.shared.generateConversationTitle(
                        userMessage: titleSeed, assistantReply: assistantContent) {
                        store.rename(conversationID, to: fmTitle)
                    }
                }
            } catch {
                if let idx = messages.indices.last, messages[idx].content.isEmpty,
                   messages[idx].toolCalls.isEmpty {
                    messages[idx].content = error.localizedDescription
                }
            }
        }
    }

    /// Conversation title from the first user message — first line, trimmed, capped.
    private static func deriveTitle(_ text: String) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "New Chat" : String(trimmed.prefix(60))
    }

    private func apply(_ event: ChatEvent) {
        guard let idx = messages.indices.last else { return }
        switch event {
        case .contentDelta(let chunk):
            messages[idx].content += chunk
        case .toolCallStart(let id, let tool, let argsJSON):
            messages[idx].toolCalls.append(ToolCall(id: id, tool: tool, argsJSON: argsJSON))
            toolCallStore?.recordStart(id: id, tool: tool, argsJSON: argsJSON, conversationId: loadedConversationID)
            // Update research progress banner from tool events — no sidecar changes needed
            if isResearching {
                switch tool {
                case "use_skill":   researchStatus = "Framing research plan..."
                case "web_search":
                    researchSearchCount += 1
                    researchStatus = "Searching the web (\(researchSearchCount))..."
                case "http_request":
                    researchReadCount += 1
                    researchStatus = "Reading sources (\(researchReadCount))..."
                case "file_write":  researchStatus = "Saving report..."
                default: break
                }
            }
        case .toolCallResult(let id, let success, let result, let latencyMs):
            if let tcIdx = messages[idx].toolCalls.firstIndex(where: { $0.id == id }) {
                // Truncate before storing — full page reads can be 100KB; keeping them
                // in memory bloats the history sent on subsequent turns and can freeze the UI.
                let stored = result.count > 3_000
                    ? result.prefix(3_000) + "\n…[truncated for display]"
                    : result
                messages[idx].toolCalls[tcIdx].result = String(stored)
                messages[idx].toolCalls[tcIdx].success = success
                messages[idx].toolCalls[tcIdx].latencyMs = latencyMs
                messages[idx].toolCalls[tcIdx].isComplete = true
                // Detect saved research report by matching file_write result to research/*.md
                // Scan original result (pre-truncation) — path is always in the first line.
                if isResearching, success,
                   messages[idx].toolCalls[tcIdx].tool == "file_write",
                   let path = Self.extractResearchPath(from: result) {
                    researchReportPath = path
                    researchStatus = "Report ready"
                }
            }
            toolCallStore?.recordResult(id: id, success: success, result: result)
        case .messageEnd(let model, _, _):
            // Stamp the resolved model on this turn so it persists (and survives a
            // mid-conversation model switch — each assistant turn records its own).
            if let model { messages[idx].model = model }
        case .error(let msg):
            if messages[idx].content.isEmpty {
                messages[idx].content = msg.isEmpty ? "Something went wrong." : msg
            }
        }
    }

    func cancelStream() { streamTask?.cancel() }

    /// Extracts a research report path from a file_write tool result string.
    /// Result format: "Wrote /path/to/research/topic.md (N chars)"
    private static func extractResearchPath(from result: String) -> String? {
        result.split(separator: " ").first(where: {
            $0.contains("/research/") && $0.hasSuffix(".md")
        }).map(String.init)
    }
}

struct ChatView: View {
    @EnvironmentObject private var store: ConversationStore
    @EnvironmentObject private var toolCallStore: ToolCallStore
    @EnvironmentObject private var reportPanel: ReportPanelState
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var inputController = ChatInputController()

    /// The active conversation's project folder (nil = independent chat) — gates
    /// the per-message "Save to memory" action on assistant bubbles.
    private var activeProjectDir: String? {
        guard let cid = store.activeConversationID else { return nil }
        return store.projectFolderPath(forConversation: cid)
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var fontSize
    @Environment(\.chatLineHeight) private var lineHeight

    @AppStorage("selectedModel") private var selectedModel = ""   // "" = Auto (sidecar resolves)
    @AppStorage("userName") private var userName = ""
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"
    @AppStorage("enabledTools") private var enabledToolsJSON = ""
    @AppStorage("systemPrompt") private var systemPrompt = ""
    @AppStorage("chatFontChoice") private var chatFontChoiceRaw = ChatFontChoice.system.rawValue
    @AppStorage("mcpHintsEnabledJSON") private var mcpHintsEnabledJSON = "{}"

    private var fontChoice: ChatFontChoice { ChatFontChoice(rawValue: chatFontChoiceRaw) ?? .system }

    @State private var inputHeight: CGFloat = 22
    @State private var inputFocused = false
    @State private var pendingAttachment: URL?
    @State private var pendingImage: NSImage?

    private var inputMinHeight: CGFloat { fontSize + 8 }
    private var inputMaxHeight: CGFloat { (fontSize + 8) * 7 }
    // Reserve scroll space for the whole input region (text field + bottom bar + padding)
    private var inputReserve: CGFloat { inputHeight + 84 }

    var body: some View {
        ZStack(alignment: .bottom) {
            messageList
            // Easter egg: Alice watches from the center until the first chat loads.
            // Once messages exist there's no way back — she only appears on fresh launch.
            if viewModel.messages.isEmpty {
                aliceEmptyState
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            // Research progress banner + input bar stacked so banner sits flush above
            VStack(spacing: 0) {
                if viewModel.isResearching, let status = viewModel.researchStatus {
                    ResearchProgressBanner(status: status)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                floatingInputBar
            }
        }
        .animation(.easeInOut(duration: 0.4), value: viewModel.messages.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isResearching)
        // Sidebar selection (or New Chat) drives which conversation is shown.
        // Guard against the self-triggered change when send() creates a new one.
        .onChange(of: store.activeConversationID) { _, newID in
            if newID != viewModel.loadedConversationID {
                reportPanel.dismiss()
                viewModel.load(newID, store: store)
            }
        }
        .task { viewModel.toolCallStore = toolCallStore }
    }

    private var aliceEmptyState: some View {
        Asset.image("alice")
            .scaledToFill()
            .frame(width: 140, height: 140)
            .clipShape(Circle())
            .opacity(0.55)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        let attachment = pendingAttachment
        pendingAttachment = nil
        pendingImage = nil
        viewModel.send(
            model: selectedModel.isEmpty ? nil : selectedModel,
            ollamaHost: ollamaHost,
            enabledTools: decodedEnabledTools(),
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            userName: userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : userName,
            mcpHintsEnabled: decodedMcpHintsEnabled(),
            researchMode: viewModel.researchMode,
            store: store,
            attachmentPath: attachment?.path
        )
    }

    /// "Consult the big model" on the latest answer — escalate to the cloud specialist.
    private func consult() {
        viewModel.escalate(
            ollamaHost: ollamaHost,
            enabledTools: decodedEnabledTools(),
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            userName: userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : userName,
            mcpHintsEnabled: decodedMcpHintsEnabled(),
            store: store
        )
    }

    private func handleImagePaste(_ image: NSImage) {
        pendingImage = image
        pendingAttachment = saveAttachment(image)
    }

    private func saveAttachment(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LGAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".png")
        try? png.write(to: url)
        return url
    }

    // Empty stored value = unconfigured → nil → sidecar enables all tools.
    private func decodedEnabledTools() -> [String]? {
        guard !enabledToolsJSON.isEmpty,
              let data = enabledToolsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return list
    }

    private func decodedMcpHintsEnabled() -> [String: Bool]? {
        guard let data = mcpHintsEnabledJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data),
              dict.values.contains(true)
        else { return nil }
        return dict
    }

    // MARK: Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            let projectDir = activeProjectDir   // resolve once per render, not per bubble
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 50)
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(viewModel.messages) { msg in
                            // Offer "Consult the big model" only on the latest local
                            // answer (not streaming, not already a cloud turn).
                            let canConsult = msg.id == viewModel.messages.last?.id
                                && msg.role == .assistant
                                && !msg.isStreaming
                                && !(msg.model?.contains("cloud") ?? false)
                            MessageBubble(message: msg, projectDir: projectDir,
                                          onConsult: canConsult ? { consult() } : nil)
                                .equatable()
                                .id(msg.id)
                        }
                        // "View Report" row — appears below last message after research completes
                        if let reportPath = viewModel.researchReportPath, !viewModel.isResearching {
                            researchCompleteRow(path: reportPath)
                                .id("research-complete")
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                        Color.clear.frame(height: inputReserve + 8).id("bottom")
                    }
                    .frame(maxWidth: 960)
                    .padding(.horizontal, 24)
                    .padding(.top, 96)
                    Spacer(minLength: 50)
                }
            }
            .defaultScrollAnchor(.bottom)
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 80)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 120)
                }
            )
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: viewModel.researchReportPath) { _, path in
                if path != nil {
                    withAnimation { proxy.scrollTo("research-complete", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func researchCompleteRow(path: String) -> some View {
        HStack {
            Spacer(minLength: 50)
            Button {
                if let path = viewModel.researchReportPath {
                    withAnimation(.easeInOut(duration: 0.28)) { reportPanel.show(path) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 12))
                    Text("View Report")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Floating input bar

    private var floatingInputBar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                if let img = pendingImage {
                    attachmentStrip(img)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                // Text field — top of the bar
                inputTextField
                // Bottom row: formatting buttons (when focused) + send/stop button
                inputBottomBar
            }
            .frame(maxWidth: 960)
            .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 30)
        .animation(.easeInOut(duration: 0.16), value: inputFocused)
    }

    private var inputTextField: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.inputText.isEmpty {
                Text(viewModel.researchMode
                     ? "What should I research?   (Enter to send · Shift+Enter for newline)"
                     : "Message Alice…   (Enter to send · Shift+Enter for newline)")
                    .font(fontChoice.font(fontSize))
                    .tracking(ChatFont.tracking(fontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .padding(.top, 7)
                    .allowsHitTesting(false)
            }
            ChatInputEditor(
                text: $viewModel.inputText,
                height: $inputHeight,
                fontSize: fontSize,
                lineHeight: lineHeight,
                fontChoice: fontChoice,
                minHeight: inputMinHeight,
                maxHeight: inputMaxHeight,
                controller: inputController,
                onSend: { submit() },
                onImagePaste: { handleImagePaste($0) },
                onFocusChange: { focused in inputFocused = focused }
            )
            .frame(height: inputHeight)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var inputBottomBar: some View {
        HStack(alignment: .center, spacing: 2) {
            if inputFocused {
                FormatButton(icon: "bold", help: "Bold") { inputController.wrap(prefix: "**", suffix: "**") }
                FormatButton(icon: "italic", help: "Italic") { inputController.wrap(prefix: "*", suffix: "*") }
                FormatButton(icon: "chevron.left.forwardslash.chevron.right", help: "Inline code") { inputController.wrap(prefix: "`", suffix: "`") }
                FormatButton(icon: "curlybraces", help: "Code block") { inputController.wrap(prefix: "\n```\n", suffix: "\n```\n") }
                FormatButton(icon: "list.bullet", help: "List item") { inputController.wrap(prefix: "\n- ", suffix: "") }
            }
            Spacer()
            // Deep Research toggle — right of formatting buttons, left of send
            Button {
                viewModel.researchMode.toggle()
                inputController.focus()
            } label: {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 15, weight: viewModel.researchMode ? .semibold : .regular))
                    .foregroundStyle(viewModel.researchMode ? Color.accentColor : Color.secondary.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(viewModel.researchMode ? Color.accentColor.opacity(0.1) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isStreaming)
            .help(viewModel.researchMode
                  ? "Deep Research active — Alice will search, read sources, and synthesize a report"
                  : "Enable Deep Research mode")
            .padding(.trailing, 4)

            Button {
                if viewModel.isStreaming { viewModel.cancelStream() } else { submit() }
            } label: {
                Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(viewModel.isStreaming ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isStreaming && viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachment == nil)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.16), value: inputFocused)
    }

    private func attachmentStrip(_ image: NSImage) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            Text("Image attached")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    pendingAttachment = nil
                    pendingImage = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

}

struct FormatButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 26, height: 24)
                .background(hovering ? Color.primary.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
