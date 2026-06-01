import SwiftUI

struct RailView: View {
    let activeTab: RailTab
    let sidebarOpen: Bool
    let onSelect: (RailTab) -> Void

    private let topTabs: [RailTab] = [.chats, .tools, .models, .monitor]

    var body: some View {
        VStack(spacing: 4) {
            Spacer().frame(height: 10)

            ForEach(topTabs, id: \.self) { tab in
                RailButton(tab: tab, isActive: isActive(tab), onTap: { onSelect(tab) })
            }

            Spacer()

            RailButton(tab: .settings, isActive: isActive(.settings), onTap: { onSelect(.settings) })
            Spacer().frame(height: 14)
        }
        .frame(width: 68)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.22), ignoresSafeAreaEdges: .all)
    }

    private func isActive(_ tab: RailTab) -> Bool {
        activeTab == tab && sidebarOpen
    }
}

struct RailButton: View {
    let tab: RailTab
    let isActive: Bool
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Active / hover background
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive
                          ? Color.accentColor.opacity(0.18)
                          : (isHovering ? Color.white.opacity(0.08) : Color.clear))
                    .frame(width: 50, height: 50)

                Image(systemName: tab.icon)
                    .font(.system(size: 20, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            }
            .frame(width: 50, height: 50)
            // contentShape ensures the full 50×50 area is hit-testable even with a clear background
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(tab.label)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}
