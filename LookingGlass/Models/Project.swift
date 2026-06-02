import Foundation

/// A row in the sidebar's projects section. Lightweight projection of a
/// `projects` row plus a chat count for display.
struct ProjectListItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let folderPath: String
    let chatCount: Int
}
