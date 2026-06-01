import SwiftUI

struct ChatHistoryPanel: View {
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            searchField
            Divider()
            historyList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panelHeader: some View {
        HStack {
            Text("Looking Glass")
                .font(.headline)
            Spacer()
            Button {
                // Phase 3: new conversation
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ChatHistoryRow(
                    title: "Current Session",
                    preview: "Alice is ready",
                    time: "Now",
                    isActive: true
                )
                // Phase 3: map persisted conversations here
            }
        }
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
