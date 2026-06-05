import SwiftUI

enum SettingsTab: String, CaseIterable {
    case style = "Style"
    case system = "System"
    case skills = "Skills"
    case mcp = "MCP"
    case about = "About"
}

struct SettingsPanel: View {
    @State private var selectedTab: SettingsTab = .style

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Settings", character: "hatter")
            Divider()
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            Group {
                switch selectedTab {
                case .style:   SettingsStyleTab()
                case .system:  SettingsSystemTab()
                case .skills:  SettingsSkillsTab()
                case .mcp:     SettingsMCPTab()
                case .about:   SettingsAboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
