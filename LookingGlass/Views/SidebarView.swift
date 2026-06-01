import SwiftUI

struct PanelHeader: View {
    let title: String
    var character: String? = nil   // asset name of the Wonderland character avatar

    var body: some View {
        HStack(spacing: 8) {
            if let character {
                Asset.image(character)
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
            }
            Text(title)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

struct SidebarView: View {
    let tab: RailTab

    var body: some View {
        Group {
            switch tab {
            case .chats:    ChatHistoryPanel()
            case .tools:    ToolCardsPanel()
            case .models:   ModelSelectorPanel()
            case .monitor:  SystemMonitorPanel()
            case .settings: SettingsPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Material gives real frosted-glass blur of whatever's behind the sidebar
        // (withinWindow blending). A faint tint adds separation from the chat area.
        .background(Color.black.opacity(0.10), ignoresSafeAreaEdges: .all)
        .background(.thinMaterial, ignoresSafeAreaEdges: .all)
    }
}
