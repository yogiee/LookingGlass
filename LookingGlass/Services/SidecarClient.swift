import Foundation

// MARK: - Domain models for Settings

struct SkillItem: Identifiable, Equatable {
    let id: String      // folder name
    let name: String    // display name from frontmatter
    let description: String
    let whenToUse: String
    let folder: String
}

struct MCPServerItem: Identifiable, Equatable {
    let id: String  // name
    let name: String
    let command: String
    let args: [String]
    let source: String  // "config" or "user"
    let prompts: [[String: String]]  // [{name, description}] — empty when server has no prompts

    var hasPrompts: Bool { !prompts.isEmpty }
}

enum MCPConnectionStatus: String {
    case connected, failed, unknown
}

enum ChatEvent {
    case contentDelta(String)
    case toolCallStart(id: String, tool: String, argsJSON: String)
    case toolCallResult(id: String, success: Bool, result: String, latencyMs: Int)
    case messageEnd(model: String?, inputTokens: Int, outputTokens: Int)
    case error(String)
}

enum SidecarError: Error, LocalizedError {
    case badResponse(Int)
    case notReachable

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "Sidecar returned HTTP \(code)"
        case .notReachable: return "Sidecar not reachable"
        }
    }
}

class SidecarClient {
    let baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!) {
        self.baseURL = baseURL
    }

    func stream(
        messages: [Message],
        model: String?,
        ollamaHost: String,
        enabledTools: [String]?,
        systemPrompt: String?,
        projectDir: String?,
        filesRoot: String? = nil,
        userName: String? = nil,
        mcpHintsEnabled: [String: Bool]? = nil,
        researchMode: Bool = false,
        specialistMode: Bool = false
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: baseURL.appending(path: "/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 300

                    var body: [String: Any] = [
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                        "ollama_host": ollamaHost,
                    ]
                    if let model { body["model"] = model }
                    // nil = let the sidecar enable all tools; a list (even empty) is honored exactly
                    if let enabledTools { body["enabled_tools"] = enabledTools }
                    // Non-empty overrides the sidecar's default Alice prompt
                    if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        body["system_prompt"] = systemPrompt
                    }
                    if let projectDir { body["project_dir"] = projectDir }
                    // User-configured save root for independent (non-project) chats.
                    // Omitted when empty/in a project — the sidecar applies its default.
                    if let filesRoot, !filesRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        body["files_root"] = filesRoot
                    }
                    if let userName, !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        body["user_name"] = userName
                    }
                    if let mcpHintsEnabled, !mcpHintsEnabled.isEmpty {
                        body["mcp_hints_enabled"] = mcpHintsEnabled
                    }
                    if researchMode { body["research_mode"] = true }
                    if specialistMode { body["specialist_mode"] = true }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: SidecarError.notReachable)
                        return
                    }
                    guard http.statusCode == 200 else {
                        continuation.finish(throwing: SidecarError.badResponse(http.statusCode))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard let data = jsonStr.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type_ = obj["type"] as? String
                        else { continue }

                        switch type_ {
                        case "content_delta":
                            if let text = obj["text"] as? String {
                                continuation.yield(.contentDelta(text))
                            }
                        case "tool_call_start":
                            let id = obj["id"] as? String ?? UUID().uuidString
                            let tool = obj["tool"] as? String ?? "tool"
                            let argsJSON = Self.prettyJSON(obj["args"])
                            continuation.yield(.toolCallStart(id: id, tool: tool, argsJSON: argsJSON))
                        case "tool_call_result":
                            let id = obj["id"] as? String ?? ""
                            let success = obj["success"] as? Bool ?? false
                            let result = obj["result"] as? String ?? ""
                            let latency = obj["latency_ms"] as? Int ?? 0
                            continuation.yield(.toolCallResult(id: id, success: success, result: result, latencyMs: latency))
                        case "message_end":
                            let usage = obj["usage"] as? [String: Int] ?? [:]
                            continuation.yield(.messageEnd(
                                model: obj["model"] as? String,
                                inputTokens: usage["input_tokens"] ?? 0,
                                outputTokens: usage["output_tokens"] ?? 0
                            ))
                            continuation.finish()
                            return
                        case "error":
                            let msg = obj["message"] as? String ?? "Unknown error"
                            continuation.yield(.error(msg))
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func health(ollamaHost: String? = nil) async -> Bool {
        var comps = URLComponents(url: baseURL.appending(path: "/health"), resolvingAgainstBaseURL: false)
        if let ollamaHost {
            comps?.queryItems = [URLQueryItem(name: "ollama_host", value: ollamaHost)]
        }
        guard let url = comps?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (json["status"] as? String) == "ok"
    }

    /// Enriched model list: live (installed ∩ chat-capable) joined with the sidecar's
    /// opinion registry. See `ModelInfo`. Empty on any failure (caller treats as offline).
    func fetchModels(ollamaHost: String? = nil) async -> [ModelInfo] {
        var comps = URLComponents(url: baseURL.appending(path: "/models"), resolvingAgainstBaseURL: false)
        if let ollamaHost {
            comps?.queryItems = [URLQueryItem(name: "ollama_host", value: ollamaHost)]
        }
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data)
        else { return [] }
        return decoded.models
    }

    /// Deterministic per-message memory save (the "Save to memory" button).
    /// Writes the exact content — no model, no re-wording. Returns success.
    @discardableResult
    func saveMemory(content: String, title: String, description: String? = nil, projectDir: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/memory/save") else { return false }
        var body: [String: Any] = ["title": title, "content": content, "project_dir": projectDir]
        if let description { body["description"] = description }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (json["success"] as? Bool) ?? false
    }

    func fetchTools() async -> [ToolInfo] {
        guard let url = URL(string: "\(baseURL)/tools"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolsArray = json["tools"] as? [[String: Any]]
        else { return [] }

        return toolsArray.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            return ToolInfo(
                name: name,
                description: dict["description"] as? String ?? "",
                category: dict["category"] as? String ?? "general",
                dangerous: dict["dangerous"] as? Bool ?? false
            )
        }
    }

    // MARK: - Skills

    func fetchSkills() async -> [SkillItem] {
        guard let url = URL(string: "\(baseURL)/skills"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["skills"] as? [[String: Any]]
        else { return [] }
        return arr.compactMap { d in
            guard let name = d["name"] as? String else { return nil }
            return SkillItem(
                id: d["folder"] as? String ?? name,
                name: name,
                description: d["description"] as? String ?? "",
                whenToUse: d["when_to_use"] as? String ?? "",
                folder: d["folder"] as? String ?? name
            )
        }
    }

    @discardableResult
    func importSkill(folderName: String, content: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/skills/import") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": folderName, "content": content])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (json["success"] as? Bool) ?? false
    }

    @discardableResult
    func deleteSkill(folderName: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/skills/\(folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folderName)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (json["success"] as? Bool) ?? false
    }

    // MARK: - MCP Servers

    func fetchMCPStatus() async -> [String: String] {
        guard let url = URL(string: "\(baseURL)/mcp/status"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["servers"] as? [String: String]
        else { return [:] }
        return servers
    }

    func fetchMCPServers() async -> [MCPServerItem] {
        guard let url = URL(string: "\(baseURL)/mcp/servers"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["servers"] as? [[String: Any]]
        else { return [] }
        return arr.compactMap { d in
            guard let name = d["name"] as? String else { return nil }
            let args = d["args"] as? [String] ?? []
            let prompts = (d["prompts"] as? [[String: String]]) ?? []
            return MCPServerItem(
                id: name,
                name: name,
                command: d["command"] as? String ?? "",
                args: args,
                source: d["source"] as? String ?? "config",
                prompts: prompts
            )
        }
    }

    @discardableResult
    func addMCPServer(name: String, command: String, args: [String], env: [String: String]) async -> Bool {
        guard let url = URL(string: "\(baseURL)/mcp/servers") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["name": name, "command": command, "args": args, "env": env]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (json["success"] as? Bool) ?? false
    }

    @discardableResult
    func deleteMCPServer(name: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/mcp/servers/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (json["success"] as? Bool) ?? false
    }

    private static func prettyJSON(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            if let value { return "\(value)" }
            return ""
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "" }
        return str
    }
}
