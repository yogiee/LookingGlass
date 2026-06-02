import SwiftUI
import AppKit
import MarkdownUI

struct MessageBubble: View {
    let message: Message
    @Environment(\.chatFontSize) private var fontSize
    @Environment(\.chatLineHeight) private var lineHeight
    @State private var isHovering = false
    @State private var hideTask: Task<Void, Never>?

    // SwiftUI Text has no line-height multiple; approximate via lineSpacing.
    private var bubbleLineSpacing: CGFloat { CGFloat(fontSize * (lineHeight - 1)) }

    // Chat prose in Roboto Mono (readable, less "terminal"); code stays in the
    // system monospace on purpose. Tracks the user's font-size + line-height.
    private var chatTheme: Theme {
        Theme()
            .text {
                ForegroundColor(.primary)
                FontFamily(.custom(ChatFont.family))
                FontSize(CGFloat(fontSize))
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.92))
                BackgroundColor(.primary.opacity(0.08))
            }
            .strong { FontWeight(.bold) }
            .emphasis { FontStyle(.italic) }
            .link { ForegroundColor(.accentColor) }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(max(0, lineHeight - 1)))
                    .markdownMargin(top: 0, bottom: 6)
            }
            .codeBlock { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.18))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.9))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .markdownMargin(top: 6, bottom: 6)
            }
            .listItem { configuration in
                configuration.label.markdownMargin(top: .em(0.12))
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
                    MessageActions(content: message.content)
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
                    .fill(Color.accentColor.opacity(0.22))
            )
            // Accent ring + soft shadow so the user turn reads as a raised card,
            // matching Alice's elevated bubble (same elevation system, accent hue).
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.40), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
    }

    private var assistantBubble: some View {
        Group {
            if message.content.isEmpty && message.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Thinking…")
                        .font(.chatProse(fontSize))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .elevatedSurface(cornerRadius: 14)
            } else if message.isStreaming {
                // Plain text while streaming — markdown is parsed once on completion
                // to avoid re-parsing partial/unclosed syntax on every token.
                Text(message.content)
                    .font(.chatProse(fontSize))
                    .lineSpacing(bubbleLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .elevatedSurface(cornerRadius: 14)
            } else {
                Markdown(message.content)
                    .markdownTheme(chatTheme)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .elevatedSurface(cornerRadius: 14)
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
    @State private var copied = false

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
        }
        .padding(.leading, 2)
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
