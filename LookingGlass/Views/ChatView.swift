import SwiftUI

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isStreaming = false
    @Published var inputText = ""

    private let client = SidecarClient()
    private var streamTask: Task<Void, Never>?

    func send(model: String?, ollamaHost: String, enabledTools: [String]?, systemPrompt: String?) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        inputText = ""
        messages.append(Message(role: .user, content: text))
        messages.append(Message(role: .assistant, content: "", isStreaming: true))
        isStreaming = true

        let history = Array(messages.dropLast())

        streamTask = Task {
            defer {
                if let idx = messages.indices.last { messages[idx].isStreaming = false }
                isStreaming = false
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
    }

    private func submit() {
        viewModel.send(
            model: selectedModel.isEmpty ? nil : selectedModel,
            ollamaHost: ollamaHost,
            enabledTools: decodedEnabledTools(),
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt
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
