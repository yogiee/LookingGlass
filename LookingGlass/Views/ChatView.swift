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
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("selectedModel") private var selectedModel = "qwen3.5:9b"
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"
    @AppStorage("enabledTools") private var enabledToolsJSON = ""
    @AppStorage("systemPrompt") private var systemPrompt = ""

    private let inputBarHeight: CGFloat = 72

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
                        Color.clear.frame(height: inputBarHeight + 8).id("bottom")
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
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Alice…", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...6)
                    .onSubmit { submit() }

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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 740)
            .background(
                colorScheme == .dark
                    ? Color.black.opacity(0.45)
                    : Color.white.opacity(0.95)
            )
            .overlay(
                colorScheme == .light
                    ? RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    : nil
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
    }
}
