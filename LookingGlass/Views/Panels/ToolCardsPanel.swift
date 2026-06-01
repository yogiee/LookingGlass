import SwiftUI

struct ToolCardsPanel: View {
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Tool Calls", character: "rabbit")
            Divider()
            emptyState
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No tool calls yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Tool activity will appear here during conversations.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
