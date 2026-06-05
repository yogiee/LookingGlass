import Foundation

enum RailTab: String, CaseIterable {
    case chats
    case tools
    case models
    case monitor
    case settings

    var icon: String {
        switch self {
        case .chats:    return "bubble.left.and.text.bubble.right"
        case .tools:    return "wrench.and.screwdriver"
        case .models:   return "snowflake.circle"
        case .monitor:  return "gauge.with.dots.needle.0percent"
        case .settings: return "gearshape"
        }
    }

    var activeIcon: String {
        switch self {
        case .chats:    return "bubble.left.and.text.bubble.right.fill"
        case .tools:    return "wrench.and.screwdriver.fill"
        case .models:   return "snowflake.circle.fill"
        case .monitor:  return "gauge.with.dots.needle.0percent"   // overridden dynamically
        case .settings: return "gearshape.fill"
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
