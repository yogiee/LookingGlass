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

    func send(model: String?, ollamaHost: String, enabledTools: [String]?, systemPrompt: String?, store: ConversationStore) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    systemPrompt: systemPrompt
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var fontSize
    @Environment(\.chatLineHeight) private var lineHeight

    @AppStorage("selectedModel") private var selectedModel = "qwen3.5:9b"
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"
    @AppStorage("enabledTools") private var enabledToolsJSON = ""
    @AppStorage("systemPrompt") private var systemPrompt = ""

    @State private var inputHeight: CGFloat = 22
    @State private var inputFocused = false

    private var inputMinHeight: CGFloat { fontSize + 8 }
    private var inputMaxHeight: CGFloat { (fontSize + 8) * 7 }
    // Reserve scroll space for the whole input region (toolbar + field + padding)
    private var inputReserve: CGFloat { inputHeight + (inputFocused ? 40 : 0) + 44 }

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
        viewModel.send(
            model: selectedModel.isEmpty ? nil : selectedModel,
            ollamaHost: ollamaHost,
            enabledTools: decodedEnabledTools(),
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            store: store
        )
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
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(viewModel.messages) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                        Color.clear.frame(height: inputReserve + 8).id("bottom")
                    }
                    .frame(maxWidth: 740)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    Spacer(minLength: 0)
                }
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: Floating input bar

    private var floatingInputBar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                if inputFocused {
                    formattingToolbar
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                inputRow
            }
            .frame(maxWidth: 740)
            // Real frosted-glass blur + a tint for contrast
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.4))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.15), lineWidth: 1)
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

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if viewModel.inputText.isEmpty {
                    Text("Message Alice…   (Enter to send · Shift+Enter for newline)")
                        .font(.system(size: fontSize, design: .monospaced))
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
                    minHeight: inputMinHeight,
                    maxHeight: inputMaxHeight,
                    controller: inputController,
                    onSend: { submit() },
                    onFocusChange: { focused in inputFocused = focused }
                )
                .frame(height: inputHeight)
            }

            Button {
                if viewModel.isStreaming { viewModel.cancelStream() } else { submit() }
            } label: {
                Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(viewModel.isStreaming ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isStreaming && viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var formattingToolbar: some View {
        HStack(spacing: 2) {
            FormatButton(icon: "bold", help: "Bold") { inputController.wrap(prefix: "**", suffix: "**") }
            FormatButton(icon: "italic", help: "Italic") { inputController.wrap(prefix: "*", suffix: "*") }
            FormatButton(icon: "chevron.left.forwardslash.chevron.right", help: "Inline code") { inputController.wrap(prefix: "`", suffix: "`") }
            FormatButton(icon: "curlybraces", help: "Code block") { inputController.wrap(prefix: "\n```\n", suffix: "\n```\n") }
            FormatButton(icon: "list.bullet", help: "List item") { inputController.wrap(prefix: "\n- ", suffix: "") }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
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
