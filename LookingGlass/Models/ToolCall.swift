import Foundation

/// A single tool invocation within an assistant turn. Created when the sidecar
/// emits `tool_call_start` and completed when `tool_call_result` arrives.
struct ToolCall: Identifiable, Equatable {
    let id: String          // e.g. "tc_0_1"
    let tool: String
    var argsJSON: String    // pretty-printed arguments
    var result: String
    var success: Bool
    var latencyMs: Int
    var isComplete: Bool

    var isThink: Bool { tool == "think" }

    init(id: String, tool: String, argsJSON: String) {
        self.id = id
        self.tool = tool
        self.argsJSON = argsJSON
        self.result = ""
        self.success = false
        self.latencyMs = 0
        self.isComplete = false
    }
}

/// Tool metadata from the sidecar's `/tools` endpoint.
struct ToolInfo: Identifiable, Codable, Equatable {
    let name: String
    let description: String
    let category: String
    let dangerous: Bool

    var id: String { name }
}
