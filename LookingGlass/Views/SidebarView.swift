import SwiftUI

struct PanelHeader: View {
    let title: String
    var character: String? = nil   // asset name of the Wonderland character avatar
    var systemIcon: String? = nil  // SF Symbol name, shown as an accent-colored circle icon
    var showAppIcon = false        // app icon in a light-tinted circle (used for Settings)

    var body: some View {
        HStack(spacing: 8) {
            if let character {
                Asset.image(character)
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
            } else if showAppIcon {
                AppIconAvatar(size: 48)
            } else if let systemIcon {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: systemIcon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    )
            }
            Text(title)
                .font(.system(size: 24, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

/// App icon in a mode-aware pastel circle — light gray in light mode (icon is dark),
/// pastel orange in dark mode (contrasts the icon's dark teal squircle).
struct AppIconAvatar: View {
    var size: CGFloat = 48
    @Environment(\.colorScheme) private var scheme

    private var bg: Color {
        scheme == .dark
            ? Color(red: 1.0, green: 0.78, blue: 0.58).opacity(0.72)  // warm peach-orange
            : Color.primary.opacity(0.08)
    }

    var body: some View {
        Circle()
            .fill(bg)
            .frame(width: size, height: size)
            .overlay(
                Asset.image("appicon")
                    .scaledToFit()
                    .frame(width: size * 0.70, height: size * 0.70)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.15, style: .continuous))
            )
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
        .background(.regularMaterial, ignoresSafeAreaEdges: .all)
    }
}
