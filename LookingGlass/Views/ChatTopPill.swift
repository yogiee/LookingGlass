import SwiftUI

/// The glass capsule above the conversation: the chat's title and one-line
/// description (with the project's colour dot and name for project chats), and on
/// the right in-chat search and delete. Spans the chat column, the same width as
/// the composer. Hovering the text shows the full title and summary in a card.
///
/// Design: WORKSPACE/mockups/chat-pill-bar.html (A1–A5, A3b).
struct ChatTopPill: View {
    let info: ActiveConversationInfo

    // Search state lives in ChatView, which also drives the bubbles' highlights.
    @Binding var isSearching: Bool
    @Binding var query: String
    /// Grabs focus for the search field: bumped by ⌘F, even when search is already open.
    let focusRequest: Int
    let matchCount: Int
    /// 0-based index of the current match; meaningless when `matchCount` is 0.
    let matchIndex: Int
    let onNextMatch: () -> Void
    let onPreviousMatch: () -> Void
    let onCloseSearch: () -> Void

    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onOpenProject: (UUID) -> Void

    static let height: CGFloat = 52

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var confirmingDelete = false
    @State private var deleteResetTask: Task<Void, Never>?
    @State private var showDetails = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            if let project = info.project {
                Circle()
                    .fill(project.resolvedColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: project.resolvedColor.opacity(0.7), radius: 4)
            }
            textBlock
            trailing
        }
        .padding(.leading, info.project == nil ? 20 : 18)
        .padding(.trailing, 9)
        .frame(height: Self.height)
        .contentShape(Capsule())
        // The pill overlaps the hidden title bar, so it moves the window like one.
        .gesture(WindowDragGesture())
        .glassEffect(.regular, in: Capsule())
        .overlay(alignment: .topLeading) {
            if showDetails {
                ChatDetailsCard(info: info)
                    .fixedSize(horizontal: false, vertical: true)   // grow past the pill's 52 pt
                    .padding(.leading, 12)
                    .offset(y: Self.height + 8)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: showDetails)
        .animation(.spring(duration: 0.26), value: isSearching)
        .animation(.spring(duration: 0.26), value: confirmingDelete)
        .onChange(of: info.id) { _, _ in
            cancelRename()
            confirmingDelete = false
            showDetails = false
        }
        .onChange(of: focusRequest) { _, _ in searchFocused = true }
        .onChange(of: isSearching) { _, searching in
            if searching { hideDetails() }
        }
    }

    // MARK: Title + description

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                if let project = info.project {
                    Button { onOpenProject(project.id) } label: {
                        Text(project.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(project.resolvedColor)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Show \(project.name) in the sidebar")
                    .layoutPriority(1)   // the chat title truncates first
                    Text("›")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
                if isRenaming {
                    TextField("Name this chat", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .semibold))
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                        .onChange(of: renameFocused) { _, focused in
                            if !focused, isRenaming { commitRename() }
                        }
                } else {
                    Text(info.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .onTapGesture(perform: beginRename)
                        .help("Click to rename")
                }
            }
            if !info.description.isEmpty {
                Text(info.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { scheduleDetails() } else { hideDetails() }
        }
    }

    // MARK: Trailing controls

    @ViewBuilder
    private var trailing: some View {
        if isSearching {
            searchField
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
        } else if confirmingDelete {
            HStack(spacing: 8) {
                Text("Delete this chat?")
                    .font(.system(size: 12.5))
                Button("Cancel") { setConfirmingDelete(false) }
                    .buttonStyle(PillTextButtonStyle(fill: Color.primary.opacity(0.12), foreground: .primary))
                Button("Delete") {
                    setConfirmingDelete(false)
                    onDelete()
                }
                .buttonStyle(PillTextButtonStyle(fill: Color(red: 1, green: 0.27, blue: 0.23), foreground: .white))
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            HStack(spacing: 2) {
                PillIconButton(systemName: "magnifyingglass", help: "Find in this chat (⌘F)") {
                    isSearching = true
                }
                PillIconButton(systemName: "trash", help: "Delete this chat") {
                    setConfirmingDelete(true)
                }
            }
            .transition(.opacity)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Find in chat", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { onPreviousMatch() } else { onNextMatch() }
                    return .handled
                }
                .onExitCommand(perform: onCloseSearch)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(matchCount == 0 ? "No matches" : "\(matchIndex + 1) of \(matchCount)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            SmallIconButton(systemName: "chevron.up", help: "Previous match (⇧↩)", action: onPreviousMatch)
                .disabled(matchCount == 0)
            SmallIconButton(systemName: "chevron.down", help: "Next match (↩)", action: onNextMatch)
                .disabled(matchCount == 0)
            SmallIconButton(systemName: "xmark", help: "Close (Esc)", action: onCloseSearch)
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .frame(width: 300, height: 34)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(searchFocused ? 0.6 : 0.25), lineWidth: 1))
        .onAppear { searchFocused = true }
    }

    // MARK: Actions

    private func beginRename() {
        hideDetails()
        draftTitle = info.title
        isRenaming = true
        DispatchQueue.main.async { renameFocused = true }   // the field must exist first
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != info.title { onRename(trimmed) }
    }

    private func cancelRename() {
        isRenaming = false
    }

    /// The confirmation backs out on its own after a few seconds, so a stray click on
    /// the trash never leaves a red Delete button waiting under the pointer.
    private func setConfirmingDelete(_ on: Bool) {
        deleteResetTask?.cancel()
        confirmingDelete = on
        guard on else { return }
        deleteResetTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { confirmingDelete = false }
        }
    }

    private func scheduleDetails() {
        guard !isSearching, !isRenaming else { return }
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { showDetails = true }
        }
    }

    private func hideDetails() {
        hoverTask?.cancel()
        showDetails = false
    }
}

// MARK: - Hover card

/// The full title and summary, shown under the pill on hover. A plain `.help()`
/// tooltip can't do a bold title or wrap a long summary, hence a card.
private struct ChatDetailsCard: View {
    let info: ActiveConversationInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleLine)
                .font(.system(size: 13.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !info.description.isEmpty {
                Text(info.description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(info.summary != nil ? "Summary by Apple Intelligence" : "Latest message — no summary yet")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    /// "Project  ›  Title", the project name in its colour.
    private var titleLine: AttributedString {
        var line = AttributedString()
        if let project = info.project {
            var name = AttributedString(project.name)
            name.foregroundColor = project.resolvedColor
            var separator = AttributedString("  ›  ")
            separator.foregroundColor = .secondary
            line += name + separator
        }
        line += AttributedString(info.title)
        return line
    }
}

// MARK: - Buttons

/// 34 pt circular icon button for the pill's resting state.
private struct PillIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

/// 24 pt icon button inside the search field.
private struct SmallIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
    }
}

/// Capsule text button for the inline delete confirmation.
private struct PillTextButtonStyle: ButtonStyle {
    let fill: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Capsule().fill(fill))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
