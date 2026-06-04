import SwiftUI

enum AppColorScheme: String, CaseIterable {
    case system = "System"
    case light  = "Light"
    case dark   = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

enum BackgroundStyle: String, CaseIterable {
    case glass          // desktop-vibrancy glass (default)
    case wonderland     // Wonderland garland backdrop
    case wonderlandWalk // Wonderland "down the path" backdrop

    var label: String {
        switch self {
        case .glass:          return "Glass"
        case .wonderland:     return "Wonderland"
        case .wonderlandWalk: return "White Rabbit"
        }
    }
}

// Environment keys so font size + line height flow down to all chat content
struct ChatFontSizeKey: EnvironmentKey {
    static let defaultValue: Double = 14.0
}

struct ChatLineHeightKey: EnvironmentKey {
    static let defaultValue: Double = 1.2
}

extension EnvironmentValues {
    var chatFontSize: Double {
        get { self[ChatFontSizeKey.self] }
        set { self[ChatFontSizeKey.self] = newValue }
    }
    var chatLineHeight: Double {
        get { self[ChatLineHeightKey.self] }
        set { self[ChatLineHeightKey.self] = newValue }
    }
}
