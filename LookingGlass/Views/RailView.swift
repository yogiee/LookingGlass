import SwiftUI

struct RailView: View {
    let activeTab: RailTab
    let sidebarOpen: Bool
    let onSelect: (RailTab) -> Void

    private let topTabs: [RailTab] = [.chats, .tools, .models, .monitor]

    var body: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 52)  // clear traffic-light area

            ForEach(topTabs, id: \.self) { tab in
                RailButton(tab: tab, isActive: isActive(tab), onTap: { onSelect(tab) })
            }

            Spacer()

            RailButton(tab: .settings, isActive: isActive(.settings), onTap: { onSelect(.settings) })
            Spacer().frame(height: 20)
        }
        .frame(width: 76)
        .frame(maxHeight: .infinity)
        // Transparent — backdrop / desktop shows through behind the buttons
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
            Image(systemName: tab.icon)
                .font(.system(size: 18, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Circle())
        .scaleEffect(isActive ? 1.15 : (isHovering ? 1.05 : 1.0))
        .brightness(isActive ? 0.15 : 0.0)
        .animation(.spring(duration: 0.2, bounce: 0.3), value: isActive)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .help(tab.label)
        .onHover { isHovering = $0 }
    }
}
