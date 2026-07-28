import SwiftUI
import AppKit
import MarkdownUI

struct MessageBubble: View, Equatable {
    let message: Message
    /// The active conversation's project folder, or nil for independent chats.
    /// When set, assistant messages get a "Save to memory" action.
    var projectDir: String? = nil
    /// Non-nil only on the latest local assistant answer — invoking it escalates the
    /// turn to the cloud specialist. The parent decides when to offer it.
    var onConsult: (() -> Void)? = nil

    /// This turn was produced by a cloud model (tag contains "cloud").
    private var isCloudTurn: Bool { message.model?.contains("cloud") ?? false }

    // Equatable: skip re-render when message content and streaming state are
    // unchanged. chatTheme and glassEffect are expensive to recompute on every
    // window resize — this prevents the main-thread stall on heavy markdown.
    // Font/env changes still propagate because @Environment invalidates separately.
    // Closures aren't comparable, so compare the consult-ability (nil vs non-nil) so
    // the button correctly appears/disappears as the latest message changes.
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message && lhs.projectDir == rhs.projectDir
            && (lhs.onConsult == nil) == (rhs.onConsult == nil)
    }
    @Environment(\.chatFontSize) private var fontSize
    @Environment(\.chatLineHeight) private var lineHeight
    @AppStorage("chatFontChoice") private var chatFontChoiceRaw = ChatFontChoice.system.rawValue
    @EnvironmentObject private var reportPanel: ReportPanelState
    @State private var isHovering = false
    @State private var hideTask: Task<Void, Never>?

    private var fontChoice: ChatFontChoice { ChatFontChoice(rawValue: chatFontChoiceRaw) ?? .system }

    // SwiftUI Text has no line-height multiple; approximate via lineSpacing.
    private var bubbleLineSpacing: CGFloat { CGFloat(fontSize * (lineHeight - 1)) }

    // On-disk images to render inline: generated images (from tool results) and
    // user-uploaded / referenced images (from `[Image: …]` markers in content).
    private var imagePaths: [String] { ImagePathScanner.paths(in: message) }
    // Content with `[Image: …]` markers stripped, so the path isn't shown as
    // literal text next to the rendered image.
    private var displayContent: String { ImagePathScanner.stripMarkers(message.content) }

    /// swift-markdown-ui renders synchronously on the main thread and STALLS on very large docs.
    /// Above the threshold the bubble shows a snippet card instead; the full document renders in the
    /// WKWebView report panel, where WebKit lays it out off the main thread.
    ///
    /// Tables take that route unconditionally, at any size. `TableView` always applies
    /// `tableDecoration`, which writes a bounds anchor per cell and reads them all back inside a
    /// `GeometryReader` whose output feeds the same layout pass that produced them — a feedback
    /// cycle that can fail to converge and wedge the main thread outright. A plain 6×6 weather table
    /// hung the app on 2026-07-26, well under the old ">10 rows" bar. Size thresholds don't help
    /// because the cost isn't volume, it's the cycle; the smallest real table can hang.
    /// (The chat list is a plain VStack now — see ChatView.messageList — which removes the lazy
    /// item-phase half of that hang, but the anchor cycle inside `TableView` is its own problem.)
    private var isHeavyMarkdown: Bool {
        let c = displayContent
        return c.count > 4000 || Self.containsTable(c)
    }

    /// True if the text contains a GFM table, spotted by its delimiter row (`|---|:--:|`) — the one
    /// line that can't be confused with prose that merely uses a pipe. Fenced code is skipped so a
    /// table *inside* a code sample doesn't demote an otherwise light message.
    private static func containsTable(_ text: String) -> Bool {
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            // Delimiter rows hold nothing but dashes, colons, pipes and spaces.
            guard t.contains("|"), t.contains("-") else { continue }
            if t.allSatisfy({ "-:| \t".contains($0) }) { return true }
        }
        return false
    }

    /// The message body — only ever mounted for non-heavy content (see isHeavyMarkdown).
    private var renderedContent: some View {
        Markdown(displayContent)
            .markdownTheme(chatTheme)
            .textSelection(.enabled)
    }

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
                // Show the prose bubble unless this turn is only tool activity /
                // images with no text of its own.
                if !displayContent.isEmpty || (message.isStreaming && message.toolCalls.isEmpty) {
                    bubbleContent
                }
                // Inline images: generated results and uploaded/referenced images.
                if !imagePaths.isEmpty {
                    ForEach(imagePaths, id: \.self) { path in
                        InlineImageView(path: path)
                            .frame(maxWidth: 360, alignment: .leading)
                    }
                }
                if message.role == .assistant {
                    HStack(spacing: 8) {
                        // Cloud turns get a persistent marker so it's always clear the
                        // answer left the machine (privacy visibility). Local turns: nothing.
                        if isCloudTurn {
                            Label(message.model ?? "Cloud", systemImage: "cloud")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .help("Generated by a cloud model — this turn left your machine.")
                        }
                        // Leading Spacer right-aligns the actions to the bubble's right edge.
                        Spacer(minLength: 0)
                        // "Consult the big model" — only offered (by the parent) on the
                        // latest local answer. The tap is the consent to use the cloud.
                        if let onConsult {
                            Button(action: onConsult) {
                                Label("Consult the big model", systemImage: "cloud.bolt")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Re-run this on the cloud specialist for more depth")
                            .opacity(isHovering && !message.isStreaming ? 1 : 0)
                        }
                        // Reveal is passed in rather than applied here: the row keeps
                        // itself visible while it's speaking, so Stop stays reachable
                        // after the pointer leaves the bubble.
                        MessageActions(
                            content: message.content,
                            messageID: message.id,
                            projectDir: projectDir,
                            revealed: isHovering && !message.isStreaming && !message.content.isEmpty
                        )
                    }
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
        // Heavy content never mounts MarkdownUI in the scroll path — a snippet
        // card opens it in the report panel instead. Alice's short conversational
        // preamble (when detectable) stays a normal bubble ABOVE the card, so her
        // dialog doesn't get swallowed into the document.
        if isHeavyMarkdown, !message.isStreaming {
            let split = DocumentSplit.split(displayContent)
            let document = split?.document ?? displayContent
            VStack(alignment: .leading, spacing: 8) {
                if let split {
                    proseBubble(split.prose)
                }
                HeavyMarkdownCard(content: document) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        reportPanel.show(text: document)
                    }
                }
            }
        } else if message.role == .user {
            userBubble
        } else {
            assistantBubble
        }
    }

    /// Assistant-bubble chrome around a plain markdown string — used for the
    /// preamble that rides above a document card (always short, safe to mount).
    private func proseBubble(_ text: String) -> some View {
        Markdown(text)
            .markdownTheme(chatTheme)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
    }

    private var userBubble: some View {
        renderedContent
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
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
                    ThinkingLabel(font: fontChoice.font(fontSize),
                                  tracking: ChatFont.tracking(fontSize))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
            } else if message.isStreaming {
                // Plain text while streaming — markdown is parsed once on completion
                // to avoid re-parsing partial/unclosed syntax on every token.
                // But a document never floods the bubble as raw markdown: once the
                // stream crosses the heavy threshold (or a detected document region
                // outgrows a preamble), the prose freezes and a composing card
                // ticks a live char count instead. Also skips re-laying-out a giant
                // Text on every token — real cost on long reports.
                let split = DocumentSplit.split(displayContent)
                let documentGrowing = isHeavyMarkdown || (split?.document.count ?? 0) > 500
                if documentGrowing {
                    VStack(alignment: .leading, spacing: 8) {
                        if let split {
                            proseBubble(split.prose)
                        }
                        ComposingDocumentCard(charCount: (split?.document ?? displayContent).count)
                    }
                } else {
                    Text(message.content)
                        .font(fontChoice.font(fontSize))
                        .tracking(ChatFont.tracking(fontSize))
                        .lineSpacing(bubbleLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
                }
            } else {
                renderedContent
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

    @AppStorage("userName") private var userName = ""

    private var initials: String {
        let n = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Y" : String(n.prefix(1).uppercased())
    }

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
                        Text(initials)
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
    let messageID: UUID
    /// Non-nil only when the chat lives in a project → enables "Save to memory".
    var projectDir: String? = nil
    /// Hover state from the parent bubble. The row can override it — see `isVisible`.
    var revealed: Bool = true
    @State private var copied = false
    @State private var savedToMemory = false
    @State private var savingToMemory = false
    /// Leaf-level subscription on purpose: MessageBubble is `.equatable()` to keep
    /// heavy markdown off the re-render path, so the speech singleton is observed
    /// here — a small view — rather than in the bubble.
    @ObservedObject private var speech = SpeechOutputService.shared
    @AppStorage(SpeechOutputService.Keys.enabled) private var voiceEnabled = true
    private let client = SidecarClient()

    private var isSpeakingThis: Bool { speech.isSpeaking(messageID.uuidString) }

    /// Visible on hover, and always while this message is being read — otherwise
    /// moving the pointer away would hide the only Stop control.
    private var isVisible: Bool { revealed || isSpeakingThis }

    var body: some View {
        HStack(spacing: 2) {
            if voiceEnabled {
                ActionButton(
                    icon: isSpeakingThis ? "stop.fill" : "speaker.wave.2",
                    label: isSpeakingThis ? "Stop" : "Read aloud"
                ) {
                    speech.toggle(content, id: messageID.uuidString)
                }
                .foregroundStyle(isSpeakingThis ? Color.accentColor : Color.secondary)
            }
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
        .opacity(isVisible ? 1 : 0)
        // Opacity alone would leave the buttons invisible but still clickable.
        .allowsHitTesting(isVisible)
        .animation(.easeInOut(duration: 0.18), value: isVisible)
    }

    private func saveToMemory() {
        guard let projectDir, !savingToMemory else { return }
        savingToMemory = true
        let title = Self.memoryTitle(from: content)
        Task {
            let description = await AppleIntelligenceService.shared.generateMemorySummary(content)
            let success = await client.saveMemory(content: content, title: title, description: description, projectDir: projectDir)
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

// MARK: - Thinking indicator (rotating, Alice-flavored)
// A little personality instead of a static "Thinking…": the word cross-fades to a new one every
// couple of seconds while Alice composes. A few Wonderland / Looking-Glass nods for the theme.
private enum ThinkingWords {
    static let all: [String] = [
        "Pondering…", "Musing…", "Percolating…", "Noodling…", "Ruminating…",
        "Mulling it over…", "Untangling…", "Connecting the dots…", "Cogitating…",
        "Scheming…", "Conjuring…", "Turning it over…", "Chewing on it…",
        "Down the rabbit hole…", "Curiouser and curiouser…", "Through the looking glass…",
        "Painting the roses…", "Chasing the white rabbit…", "Six impossible things…",
        "Consulting the Cheshire Cat…",
    ]
    static func random(excluding current: String? = nil) -> String {
        let pool = current.map { c in all.filter { $0 != c } } ?? all
        return pool.randomElement() ?? "Thinking…"
    }
}

struct ThinkingLabel: View {
    let font: Font
    let tracking: CGFloat
    @State private var phrase = ThinkingWords.random()

    var body: some View {
        Text(phrase)
            .font(font)
            .tracking(tracking)
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
            .task {
                // Auto-cancels when the bubble stops "thinking" (view disappears once content streams in).
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2.2))
                    withAnimation(.easeInOut(duration: 0.35)) {
                        phrase = ThinkingWords.random(excluding: phrase)
                    }
                }
            }
    }
}
