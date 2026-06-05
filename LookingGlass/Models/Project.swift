import Foundation
import SwiftUI

// MARK: - Project color

enum ProjectColor: String, CaseIterable {
    case defaultBlue = "default"
    case red         = "red"
    case orange      = "orange"
    case yellow      = "yellow"
    case green       = "green"
    case teal        = "teal"
    case purple      = "purple"
    case pink        = "pink"

    var color: Color {
        switch self {
        case .defaultBlue: return .accentColor
        case .red:         return Color(red: 0.90, green: 0.25, blue: 0.22)
        case .orange:      return Color(red: 0.95, green: 0.55, blue: 0.15)
        case .yellow:      return Color(red: 0.92, green: 0.78, blue: 0.10)
        case .green:       return Color(red: 0.25, green: 0.72, blue: 0.38)
        case .teal:        return Color(red: 0.10, green: 0.68, blue: 0.72)
        case .purple:      return Color(red: 0.55, green: 0.28, blue: 0.85)
        case .pink:        return Color(red: 0.95, green: 0.35, blue: 0.62)
        }
    }
}

// MARK: - Project list item

/// A row in the sidebar's projects section. Lightweight projection of a
/// `projects` row plus a chat count for display.
struct ProjectListItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let description: String
    let folderPath: String
    let chatCount: Int
    let color: ProjectColor

    var resolvedColor: Color { color.color }
}
