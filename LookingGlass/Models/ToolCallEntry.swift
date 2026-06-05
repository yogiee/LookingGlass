import Foundation

struct ToolCallEntry: Identifiable {
    let id: String          // tc_1, etc. — matches SSE id
    let tool: String
    var status: Status
    let argsPreview: String
    var resultSnippet: String?
    let timestamp: Date
    let conversationId: UUID?

    enum Status {
        case running, success, failed
    }
}
