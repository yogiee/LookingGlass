import SwiftUI

struct ToolCardsPanel: View {
    @EnvironmentObject private var toolCallStore: ToolCallStore
    @EnvironmentObject private var conversationStore: ConversationStore

    @State private var filter: FilterMode = .all
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    enum FilterMode: String, CaseIterable {
        case current = "Current"
        case all = "All"
    }

    private var activeConversationId: UUID? {
        conversationStore.activeConversationID
    }

    private var filtered: [ToolCallEntry] {
        let base: [ToolCallEntry] = {
            switch filter {
            case .all:
                return toolCallStore.entries
            case .current:
                guard let cid = activeConversationId else { return [] }
                return toolCallStore.entries.filter { $0.conversationId == cid }
            }
        }()
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter {
            $0.tool.lowercased().contains(q)
            || $0.argsPreview.lowercased().contains(q)
            || ($0.resultSnippet?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Tool Calls", character: "caterpillar") {
                filterPicker
            }
            .onChange(of: activeConversationId) { _, newID in
                if newID == nil && filter == .current { filter = .all }
            }
            searchBar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filter picker (inline segmented buttons)

    private var filterPicker: some View {
        HStack(spacing: 0) {
            filterButton(.current, enabled: activeConversationId != nil)
            filterButton(.all, enabled: true)
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    @ViewBuilder
    private func filterButton(_ mode: FilterMode, enabled: Bool) -> some View {
        let selected = filter == mode
        Button {
            guard enabled else { return }
            filter = mode
        } label: {
            Text(mode.rawValue)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(selected ? Color.white : (enabled ? Color.primary : Color.secondary.opacity(0.4)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField("Search tool calls…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { entry in
                        ToolCallEntryCard(entry: entry)
                    }
                }
                .padding(12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if !searchText.isEmpty { return "No tool calls match \"\(searchText)\"" }
        if filter == .current && activeConversationId == nil { return "No conversation open" }
        if filter == .current { return "No tool calls in this conversation yet" }
        return "Tool calls will appear here during conversations"
    }
}

// MARK: - Entry Card

struct ToolCallEntryCard: View {
    let entry: ToolCallEntry
    @State private var expanded = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 10) {
                Image(systemName: toolIcon(entry.tool))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(statusColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.tool)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(entry.argsPreview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    statusBadge
                    Text(entry.timestamp, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture {
                if entry.resultSnippet != nil {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
            }

            // Expandable result
            if expanded, let snippet = entry.resultSnippet {
                Divider().padding(.horizontal, 12)
                Text(snippet)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var statusColor: Color {
        switch entry.status {
        case .running: return .secondary
        case .success: return .accentColor
        case .failed:  return .red
        }
    }

    private var statusBadge: some View {
        Group {
            switch entry.status {
            case .running:
                HStack(spacing: 3) {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                    Text("Running").font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            case .success:
                Label("Done", systemImage: "checkmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
            case .failed:
                Label("Failed", systemImage: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
    }

    private var cardBackground: some View {
        Group {
            if colorScheme == .dark {
                Color.white.opacity(0.07)
            } else {
                Color.black.opacity(0.05)
            }
        }
    }
}

// MARK: - Tool → SF Symbol map

private func toolIcon(_ tool: String) -> String {
    switch tool.lowercased() {
    case let t where t.contains("search"):      return "magnifyingglass"
    case let t where t.contains("file") || t.contains("read") || t.contains("write"):
                                                return "doc.text"
    case let t where t.contains("shell") || t.contains("exec") || t.contains("bash"):
                                                return "terminal"
    case let t where t.contains("http") || t.contains("request") || t.contains("fetch"):
                                                return "network"
    case let t where t.contains("think"):       return "brain"
    case let t where t.contains("image") || t.contains("vision") || t.contains("describe"):
                                                return "photo"
    case let t where t.contains("memory") || t.contains("recall") || t.contains("save"):
                                                return "memorychip"
    case let t where t.contains("skill"):       return "graduationcap"
    case let t where t.contains("browser") || t.contains("navigate"):
                                                return "safari"
    default:                                    return "wrench.and.screwdriver"
    }
}
