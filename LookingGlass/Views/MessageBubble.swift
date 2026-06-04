import SwiftUI
import AppKit
import MarkdownUI

struct MessageBubble: View {
    let message: Message
    /// The active conversation's project folder, or nil for independent chats.
    /// When set, assistant messages get a "Save to memory" action.
    var projectDir: String? = nil
    @Environment(\.chatFontSize) private var fontSize
    @Environment(\.chatLineHeight) private var lineHeight
    @AppStorage("chatFontChoice") private var chatFontChoiceRaw = ChatFontChoice.system.rawValue
    @State private var isHovering = false
    @State private var hideTask: Task<Void, Never>?

    private var fontChoice: ChatFontChoice { ChatFontChoice(rawValue: chatFontChoiceRaw) ?? .system }

    // SwiftUI Text has no line-height multiple; approximate via lineSpacing.
    private var bubbleLineSpacing: CGFloat { CGFloat(fontSize * (lineHeight - 1)) }

    // GitHub-flavored rendering, adapted to the chat. Built on MarkdownUI's
    // GitHub theme (headings with rules, blockquotes with a left bar, alternating
    // -row tables, task lists, thematic breaks) but with our chat voice: San
    // Francisco prose + tracking at the Settings font-size, the line-height from
    // Settings, and our own translucent code background. Code stays monospace and
    // un-tracked. Single-knob font swap lives in ChatFont.
    private var chatTheme: Theme {
        Theme.gitHub
            .text {
                ForegroundColor(.primary)
                FontFamily(fontChoice.markdownFamily)
                FontSize(CGFloat(fontSize))
                TextTracking(ChatFont.tracking(fontSize))
            }
            .code {
                // Mono pairing for the chosen prose font (else system SF Mono).
                if let codeFamily = fontChoice.codeFamily {
                    FontFamily(.custom(codeFamily))
                } else {
                    FontFamilyVariant(.monospaced)
                }
                FontSize(.em(0.88))
                BackgroundColor(.primary.opacity(0.08))
                TextTracking(0)   // code stays tight; don't inherit prose tracking
            }
            .strong { FontWeight(.semibold) }
            .link { ForegroundColor(.accentColor) }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(max(0, lineHeight - 1)))
                    .markdownMargin(top: 0, bottom: 12)
            }
            .codeBlock { configuration in
                // Wrap long lines (chat bubbles are narrow) rather than GitHub's
                // horizontal scroll; keep our translucent block background.
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        if let codeFamily = fontChoice.codeFamily {
                            FontFamily(.custom(codeFamily))
                        } else {
                            FontFamilyVariant(.monospaced)
                        }
                        FontSize(.em(0.88))
                        TextTracking(0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .markdownMargin(top: 16, bottom: 16)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(.secondary) }
                        .padding(.leading, 14)
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 16, bottom: 16)
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: .primary.opacity(0.18)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(Color.clear, Color.primary.opacity(0.05))
                    )
                    .markdownMargin(top: 16, bottom: 16)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 { FontWeight(.semibold) }
                        BackgroundColor(nil)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 16)
                    .relativeLineSpacing(.em(0.25))
            }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Sized to roughly match a single-line bubble (text + vertical padding)
            AvatarView(role: message.role, size: fontSize + 28)

            VStack(alignment: .leading, spacing: 6) {
                // Tool activity renders as cards above the prose answer
                if !message.toolCalls.isEmpty {
                    ForEach(message.toolCalls) { call in
                        ToolCallCard(call: call)
                            .frame(maxWidth: 520, alignment: .leading)
                    }
                }
                if !(message.content.isEmpty && !message.toolCalls.isEmpty) {
                    bubbleContent
                }
                if message.role == .assistant {
                    // Leading Spacer (min width 0) right-aligns the actions to the
                    // bubble's right edge without widening the column.
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        MessageActions(content: message.content, projectDir: projectDir)
                    }
                    .opacity(isHovering && !message.isStreaming && !message.content.isEmpty ? 1 : 0)
                }
            }

            Spacer(minLength: 0)
        }
        // contentShape makes the full row width (including the Spacer) hit-testable
        .contentShape(Rectangle())
        .onHover { hovering in
            hideTask?.cancel()
            if hovering {
                isHovering = true
            } else {
                // Brief delay so moving mouse between bubble and action buttons
                // doesn't trigger a hide mid-transition
                hideTask = Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    if !Task.isCancelled { isHovering = false }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isHovering)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.role == .user {
            userBubble
        } else {
            assistantBubble
        }
    }

    private var userBubble: some View {
        Markdown(message.content)
            .markdownTheme(chatTheme)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.25))
            )
            .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
    }

    private var assistantBubble: some View {
        Group {
            if message.content.isEmpty && message.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Thinking…")
                        .font(fontChoice.font(fontSize))
                        .tracking(ChatFont.tracking(fontSize))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
            } else if message.isStreaming {
                // Plain text while streaming — markdown is parsed once on completion
                // to avoid re-parsing partial/unclosed syntax on every token.
                Text(message.content)
                    .font(fontChoice.font(fontSize))
                    .tracking(ChatFont.tracking(fontSize))
                    .lineSpacing(bubbleLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
            } else {
                Markdown(message.content)
                    .markdownTheme(chatTheme)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

// MARK: - Avatar

struct AvatarView: View {
    let role: Message.Role
    var size: CGFloat = 30
    @AppStorage("userAvatarVersion") private var userAvatarVersion = 0

    var body: some View {
        Group {
            if role == .assistant {
                Asset.image("alice")
                    .scaledToFill()
            } else if let custom = AvatarStore.userAvatar(version: userAvatarVersion) {
                Image(nsImage: custom)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.accentColor)
                    .overlay(
                        Text("Y")
                            .font(.system(size: size * 0.42, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Action buttons

struct MessageActions: View {
    let content: String
    /// Non-nil only when the chat lives in a project → enables "Save to memory".
    var projectDir: String? = nil
    @State private var copied = false
    @State private var savedToMemory = false
    @State private var savingToMemory = false
    private let client = SidecarClient()

    var body: some View {
        HStack(spacing: 2) {
            ActionButton(icon: copied ? "checkmark" : "doc.on.doc", label: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { copied = false }
                }
            }
            ActionButton(icon: "arrow.down.circle", label: "Save as Markdown") {
                saveMarkdown()
            }
            // Surgical save: stores this message verbatim into the project's
            // memory-bank — no model, no re-wording. Only inside a project.
            if projectDir != nil {
                ActionButton(
                    icon: savedToMemory ? "checkmark" : "brain",
                    label: savedToMemory ? "Saved to memory" : "Save to memory"
                ) {
                    saveToMemory()
                }
                .disabled(savingToMemory)
            }
        }
        .padding(.trailing, 2)
    }

    private func saveToMemory() {
        guard let projectDir, !savingToMemory else { return }
        savingToMemory = true
        let title = Self.memoryTitle(from: content)
        Task {
            let success = await client.saveMemory(content: content, title: title, projectDir: projectDir)
            await MainActor.run {
                savingToMemory = false
                guard success else { return }
                withAnimation { savedToMemory = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { savedToMemory = false }
                }
            }
        }
    }

    /// Deterministic title from the message's first meaningful line (the sidecar
    /// slugifies it for the filename). Content itself is saved verbatim.
    static func memoryTitle(from content: String) -> String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? content
        var t = firstLine.trimmingCharacters(in: .whitespaces)
        while let f = t.first, "#-*>•".contains(f) { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.count > 60 { t = String(t.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" }
        return t.isEmpty ? "Saved note" : t
    }

    private func saveMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "alice-response.md"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

struct ActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(hovering ? Color.primary.opacity(0.08) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(label)
        .onHover { hovering = $0 }
    }
}
