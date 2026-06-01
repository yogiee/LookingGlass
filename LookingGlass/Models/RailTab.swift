import Foundation

enum RailTab: String, CaseIterable {
    case chats
    case tools
    case models
    case monitor
    case settings

    var icon: String {
        switch self {
        case .chats:    return "bubble.left.and.bubble.right"
        case .tools:    return "wrench.and.screwdriver"
        case .models:   return "cpu"
        case .monitor:  return "chart.bar"
        case .settings: return "gearshape"
        }
    }

    var label: String {
        switch self {
        case .chats:    return "Chats"
        case .tools:    return "Tools"
        case .models:   return "Models"
        case .monitor:  return "Monitor"
        case .settings: return "Settings"
        }
    }
}
