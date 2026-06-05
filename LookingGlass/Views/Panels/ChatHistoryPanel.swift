import SwiftUI

struct ChatHistoryPanel: View {
    @EnvironmentObject private var store: ConversationStore
    @State private var showingNewProject = false
    @State private var showingEditProject = false
    @State private var projectToEdit: ProjectListItem? = nil
    @State private var hoveringFolderBack = false
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var borderColor: Color { colorScheme == .dark ? .white : .black }

    /// Inline-rename state: which row is being edited and its working title.
    @State private var editingID: UUID?
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool

    private var inProjectView: Bool { store.activeProjectID != nil }

    var body: some View {
        VStack(spacing: 0) {
            if inProjectView, let project = store.activeProject {
                projectHeader(project)
            } else {
                rootHeader
            }
            searchField
            Divider()
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet { name, description, folder, guidelines, color in
                store.createProject(name: name, description: description,
                                    folderURL: folder, guidelines: guidelines, color: color)
            }
        }
        .sheet(isPresented: $showingEditProject) {
            if let project = projectToEdit {
                EditProjectSheet(project: project) { name, description, color in
                    store.updateProject(id: project.id, name: name, description: description, color: color)
                }
            }
        }
        // Clicking away from an open rename field commits it (Enter/Esc are
        // handled in the row and clear editingID first, so this won't double-fire).
        .onChange(of: renameFocused) { _, focused in
            if !focused, editingID != nil { commitRename() }
        }
    }

    // MARK: Headers

    private var rootHeader: some View {
        HStack(spacing: 8) {
            Asset.image("alice")
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(borderColor, lineWidth: 2))
            Text("Looking Glass")
                .font(.system(size: 24, weight: .semibold))
            Spacer()
            Button { showingNewProject = true } label: {
                Image(systemName: "folder.badge.plus").font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New project")

            Button { store.startNewChat() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New chat")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func projectHeader(_ project: ProjectListItem) -> some View {
        HStack(spacing: 8) {
            folderBackButton(color: project.resolvedColor)

            Text(project.name)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(project.name)
            Spacer()
            Button {
                projectToEdit = project
                showingEditProject = true
            } label: {
                Image(systemName: "pencil").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Edit project")

            Button { store.startNewChat() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New chat in this project")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func folderBackButton(color: Color) -> some View {
        Circle()
            .fill(color.opacity(0.15))
            .frame(width: 48, height: 48)
            .overlay(
                Circle()
                    .fill(Color.black.opacity(hoveringFolderBack ? 0.32 : 0))
            )
            .overlay(
                ZStack {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(color)
                        .opacity(hoveringFolderBack ? 0 : 1)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(hoveringFolderBack ? 1 : 0)
                }
            )
            .overlay(
                Circle().strokeBorder(borderColor.opacity(0.75), lineWidth: 2)
            )
            .animation(.easeInOut(duration: 0.15), value: hoveringFolderBack)
            .onHover { hoveringFolderBack = $0 }
            .onTapGesture { store.exitProject() }
            .help("Back to all chats")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField(inProjectView ? "Search this project" : "Search", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
            if !store.searchText.isEmpty {
                Button { store.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(searchFocused ? Color.primary.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(searchFocused ? 0.22 : 0.10), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.15), value: searchFocused)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !inProjectView && !store.projects.isEmpty {
                    sectionLabel("Projects")
                    ForEach(store.projects) { project in
                        ProjectRow(project: project)
                            .contentShape(Rectangle())
                            .onTapGesture { store.openProject(project.id) }
                            .contextMenu {
                                Button("Edit Project…") {
                                    projectToEdit = project
                                    showingEditProject = true
                                }
                                Divider()
                                Button("Delete Project (keeps chats & files)", role: .destructive) {
                                    store.deleteProject(project.id)
                                }
                            }
                    }
                    sectionLabel("Chats")
                }

                if store.conversations.isEmpty {
                    emptyState
                } else {
                    ForEach(store.conversations) { item in
                        ChatHistoryRow(
                            title: item.title.isEmpty ? "Untitled" : item.title,
                            preview: item.preview.isEmpty ? "No messages yet" : item.preview,
                            time: Self.relativeTime(item.updatedAt),
                            isActive: item.id == store.activeConversationID,
                            isEditing: editingID == item.id,
                            draftTitle: $draftTitle,
                            renameFocused: $renameFocused,
                            onCommitRename: commitRename,
                            onCancelRename: cancelRename,
                            onRename: { beginRename(item) },
                            onDelete: { store.delete(item.id) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if editingID != item.id { store.activeConversationID = item.id }
                        }
                        .contextMenu { chatContextMenu(item) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chatContextMenu(_ item: ConversationListItem) -> some View {
        Button("Rename") { beginRename(item) }
        if inProjectView {
            Button("Remove from Project") {
                store.moveConversation(item.id, toProject: nil)
            }
        } else if !store.allProjects.isEmpty {
            Menu("Move to Project") {
                ForEach(store.allProjects) { project in
                    Button(project.name) {
                        store.moveConversation(item.id, toProject: project.id)
                    }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(item.id) }
    }

    // MARK: Inline rename

    private func beginRename(_ item: ConversationListItem) {
        draftTitle = item.title
        editingID = item.id
        // Defer focus until the TextField exists in the hierarchy.
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        guard let id = editingID else { return }
        store.rename(id, to: draftTitle)   // no-op on blank → keeps prior title
        editingID = nil
    }

    private func cancelRename() {
        editingID = nil
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: store.searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 16)
    }

    private var emptyMessage: String {
        if !store.searchText.isEmpty { return "No matches" }
        return inProjectView ? "No chats in this project yet" : "No conversations yet"
    }

    /// "Now" / "5m" / "3h" / "2d" / "Apr 7".
    static func relativeTime(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60:      return "Now"
        case ..<3600:    return "\(Int(seconds / 60))m"
        case ..<86_400:  return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}

struct ProjectRow: View {
    let project: ProjectListItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 16))
                .foregroundStyle(project.resolvedColor.opacity(0.8))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(project.chatCount == 1 ? "1 chat" : "\(project.chatCount) chats")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct ChatHistoryRow: View {
    let title: String
    let preview: String
    let time: String
    let isActive: Bool
    let isEditing: Bool
    @Binding var draftTitle: String
    var renameFocused: FocusState<Bool>.Binding
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("Name this chat", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .focused(renameFocused)
                        .onSubmit(onCommitRename)
                        .onExitCommand(perform: onCancelRename)   // Esc
                } else {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                }
                Text(preview)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Time by default; hover swaps in rename/delete actions. Hidden while
            // editing so the field has room.
            if !isEditing {
                if hovering {
                    HStack(spacing: 10) {
                        actionButton("pencil", help: "Rename", action: onRename)
                        actionButton("trash", help: "Delete", action: onDelete)
                    }
                } else {
                    Text(time)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        // Inset rounded highlight: accent fill + ring when selected, a light
        // wash on hover. Gives each row a clear card-like footprint instead of
        // dissolving into the panel.
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isActive ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var rowFill: Color {
        if isActive { return Color.accentColor.opacity(0.18) }
        if hovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    private func actionButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
