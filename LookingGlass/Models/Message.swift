import Foundation

struct Message: Identifiable, Equatable {
    let id: UUID
    var role: Role
    var content: String
    var isStreaming: Bool
    var toolCalls: [ToolCall]

    enum Role: String, Codable {
        case user
        case assistant
    }

    init(id: UUID = UUID(), role: Role, content: String, isStreaming: Bool = false, toolCalls: [ToolCall] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.toolCalls = toolCalls
    }
}
