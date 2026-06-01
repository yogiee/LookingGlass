import SwiftUI

struct ChatHistoryPanel: View {
    @EnvironmentObject private var store: ConversationStore
    @State private var showingNewProject = false

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
            NewProjectSheet { name, description, folder, guidelines in
                store.createProject(name: name, description: description,
                                    folderURL: folder, guidelines: guidelines)
            }
        }
    }

    // MARK: Headers

    private var rootHeader: some View {
        HStack(spacing: 4) {
            Text("Looking Glass")
                .font(.headline)
            Spacer()
            Button { showingNewProject = true } label: {
                Image(systemName: "folder.badge.plus").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New project")

            Button { store.startNewChat() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New chat")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func projectHeader(_ project: ProjectListItem) -> some View {
        HStack(spacing: 8) {
            Button { store.exitProject() } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to all chats")

            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(project.name)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button { store.startNewChat() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New chat in this project")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField(inProjectView ? "Search this project" : "Search", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !store.searchText.isEmpty {
                Button { store.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                            isActive: item.id == store.activeConversationID
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { store.activeConversationID = item.id }
                        .contextMenu { chatContextMenu(item) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chatContextMenu(_ item: ConversationListItem) -> some View {
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
        Button("Delete", role: .destructive) { store.delete(item.id) }
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
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
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.system(size: 12))
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(project.chatCount == 1 ? "1 chat" : "\(project.chatCount) chats")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

struct ChatHistoryRow: View {
    let title: String
    let preview: String
    let time: String
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(time)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
    }
}
