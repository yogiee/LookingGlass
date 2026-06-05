import SwiftUI

struct RailView: View {
    let activeTab: RailTab
    let sidebarOpen: Bool
    let systemMonitor: SystemMonitor
    let onSelect: (RailTab) -> Void

    private let topTabs: [RailTab] = [.chats, .tools, .models, .monitor]

    private var vramFill: Double {
        guard systemMonitor.ramTotalGB > 0 else { return 0 }
        return systemMonitor.ollamaVRAMGB / systemMonitor.ramTotalGB
    }

    private func gaugeIcon(for fill: Double) -> String {
        switch fill {
        case 0.9...: return "gauge.open.with.lines.needle.84percent.exclamation"
        case 0.6...: return "gauge.open.with.lines.needle.67percent.and.arrowtriangle"
        case 0.3...: return "gauge.open.with.lines.needle.33percent.and.arrowtriangle"
        default:     return "gauge.with.dots.needle.0percent"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 52)  // clear traffic-light area

            ForEach(topTabs, id: \.self) { tab in
                let icon = tab == .monitor
                    ? gaugeIcon(for: vramFill)
                    : (isActive(tab) ? tab.activeIcon : tab.icon)
                RailButton(icon: icon, isActive: isActive(tab), help: tab.label, onTap: { onSelect(tab) })
            }

            Spacer()

            let settingsIcon = isActive(.settings) ? RailTab.settings.activeIcon : RailTab.settings.icon
            RailButton(icon: settingsIcon, isActive: isActive(.settings), help: RailTab.settings.label, onTap: { onSelect(.settings) })
            Spacer().frame(height: 20)
        }
        .frame(width: 76)
        .frame(maxHeight: .infinity)
    }

    private func isActive(_ tab: RailTab) -> Bool {
        activeTab == tab && sidebarOpen
    }
}

struct RailButton: View {
    let icon: String
    let isActive: Bool
    let help: String
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: icon)
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
        .help(help)
        .onHover { isHovering = $0 }
    }
}
