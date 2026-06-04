import SwiftUI

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isStreaming = false
    @Published var inputText = ""

    /// The conversation currently mirrored in `messages`. Kept in sync with the
    /// store's `activeConversationID`; `nil` = an unsaved fresh chat.
    private(set) var loadedConversationID: UUID?

    private let client = SidecarClient()
    private var streamTask: Task<Void, Never>?

    /// Swap the chat pane to a different conversation (or a blank one for `nil`).
    func load(_ conversationID: UUID?, store: ConversationStore) {
        streamTask?.cancel()
        isStreaming = false
        loadedConversationID = conversationID
        messages = conversationID.map { store.loadMessages($0) } ?? []
    }

    func send(model: String?, ollamaHost: String, enabledTools: [String]?, systemPrompt: String?, store: ConversationStore, attachmentPath: String? = nil) {
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
        messages.append(Message(role: .assistant, content: "", isStreaming: true))
        isStreaming = true

        // Ensure a persisted conversation exists, then save the user's turn.
        // Setting loadedConversationID *before* activeConversationID means the
        // view's onChange guard treats this as "already loaded" and won't reload.
        let conversationID: UUID
        if let active = loadedConversationID {
            conversationID = active
        } else {
            let newID = store.createConversation(title: Self.deriveTitle(text))
            loadedConversationID = newID
            store.activeConversationID = newID
            conversationID = newID
        }
        store.appendMessage(userMessage, to: conversationID)

        let history = Array(messages.dropLast())
        // Where this conversation lives — sent so the sidecar scopes tools and
        // reads project.toml/guidelines.md. nil for independent chats.
        let projectDir = store.projectFolderPath(forConversation: conversationID)

        streamTask = Task {
            defer {
                if let idx = messages.indices.last { messages[idx].isStreaming = false }
                isStreaming = false
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
                    projectDir: projectDir
                ) {
                    guard !Task.isCancelled else { break }
                    apply(event)
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
        case .toolCallResult(let id, let success, let result, let latencyMs):
            if let tcIdx = messages[idx].toolCalls.firstIndex(where: { $0.id == id }) {
                messages[idx].toolCalls[tcIdx].result = result
                messages[idx].toolCalls[tcIdx].success = success
                messages[idx].toolCalls[tcIdx].latencyMs = latencyMs
                messages[idx].toolCalls[tcIdx].isComplete = true
            }
        case .messageEnd:
            break
        case .error(let msg):
            if messages[idx].content.isEmpty {
                messages[idx].content = msg.isEmpty ? "Something went wrong." : msg
            }
        }
    }

    func cancelStream() { streamTask?.cancel() }
}

struct ChatView: View {
    @EnvironmentObject private var store: ConversationStore
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
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"
    @AppStorage("enabledTools") private var enabledToolsJSON = ""
    @AppStorage("systemPrompt") private var systemPrompt = ""
    @AppStorage("chatFontChoice") private var chatFontChoiceRaw = ChatFontChoice.system.rawValue

    private var fontChoice: ChatFontChoice { ChatFontChoice(rawValue: chatFontChoiceRaw) ?? .system }

    @State private var inputHeight: CGFloat = 22
    @State private var inputFocused = false
    @State private var pendingAttachment: URL?
    @State private var pendingImage: NSImage?

    private var inputMinHeight: CGFloat { fontSize + 8 }
    private var inputMaxHeight: CGFloat { (fontSize + 8) * 7 }
    // Reserve scroll space for the whole input region (text field + bottom bar + padding)
    private var inputReserve: CGFloat { inputHeight + 80 }

    var body: some View {
        ZStack(alignment: .bottom) {
            messageList
            floatingInputBar
        }
        // Sidebar selection (or New Chat) drives which conversation is shown.
        // Guard against the self-triggered change when send() creates a new one.
        .onChange(of: store.activeConversationID) { _, newID in
            if newID != viewModel.loadedConversationID {
                viewModel.load(newID, store: store)
            }
        }
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
            store: store,
            attachmentPath: attachment?.path
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

    // MARK: Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            let projectDir = activeProjectDir   // resolve once per render, not per bubble
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 50)
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(viewModel.messages) { msg in
                            MessageBubble(message: msg, projectDir: projectDir)
                                .id(msg.id)
                                .scrollTransition(.interactive) { content, phase in
                                    let raw = abs(phase.value)
                                    let v = raw < 0.35 ? 0 : (raw - 0.35) / 0.65
                                    return content
                                        .blur(radius: 12 * v)
                                        .opacity(max(0.35, 1.0 - 0.65 * v))
                                }
                        }
                        Color.clear.frame(height: inputReserve + 8).id("bottom")
                    }
                    .frame(maxWidth: 960)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    Spacer(minLength: 50)
                }
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            // Glass shelf: blurs content scrolling under the top/bottom edges.
            // Top edge ignores safe area so it sits flush under the titlebar.
            .overlay(alignment: .top) {
                GlassEdge(atTop: true)
                    .frame(height: 70)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                GlassEdge(atTop: false)
                    .frame(height: 90)
                    .allowsHitTesting(false)
            }
        }
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
            // Real frosted-glass blur + a tint for contrast
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(colorScheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.4))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.28 : 0.15), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(
                color: colorScheme == .dark ? .black.opacity(0.3) : .black.opacity(0.08),
                radius: 14, x: 0, y: 6
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .animation(.easeInOut(duration: 0.16), value: inputFocused)
    }

    private var inputTextField: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.inputText.isEmpty {
                Text("Message Alice…   (Enter to send · Shift+Enter for newline)")
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
