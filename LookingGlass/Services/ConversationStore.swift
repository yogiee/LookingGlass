import Foundation
import GRDB

/// SQLite-backed persistence for conversations, messages, and projects (Phase 3,
/// Steps 1–2). The sidebar is a hybrid: independent chats (`project_id IS NULL`)
/// alongside folder-bound **projects** that group chats.
///
/// This store is the single source of truth for the sidebar's two navigation
/// axes:
///   • `activeProjectID` — which view the sidebar shows (nil = root, set = that
///     project's chats). Pure navigation.
///   • `activeConversationID` — which conversation is open in the chat pane.
///
/// `ChatViewModel` loads/persists messages *through* this store. A fresh chat's
/// project is decided by `activeProjectID` at send time, so where you are when
/// you send is where the chat lands. See
/// WORKSPACE/phase3-projects-and-persistence.md §2–6.
///
/// DB writes are synchronous on the main actor: single-row SQLite writes are
/// sub-millisecond, so blocking is imperceptible and the code stays simple.
@MainActor
final class ConversationStore: ObservableObject {
    /// Chats for the current view: independent chats in root, the project's chats
    /// in project view. Newest first, honoring `searchText`.
    @Published private(set) var conversations: [ConversationListItem] = []

    /// Projects shown in the root view's projects section (search-filtered).
    @Published private(set) var projects: [ProjectListItem] = []

    /// Every (non-archived) project — for context menus and lookups, regardless
    /// of the current view.
    @Published private(set) var allProjects: [ProjectListItem] = []

    /// The project whose view is currently shown (header), or nil in root view.
    @Published private(set) var activeProject: ProjectListItem?

    /// Sidebar navigation. nil = root view; set = that project's view.
    @Published var activeProjectID: UUID? {
        didSet { if activeProjectID != oldValue { reload() } }
    }

    /// The conversation open in the chat pane. nil = a fresh, unsaved chat (the
    /// row is created lazily on first send, scoped to `activeProjectID`).
    @Published var activeConversationID: UUID?

    /// Sidebar search. Root view searches everything (independent chats, plus
    /// projects by name or contained-chat match); project view scopes to that
    /// project's chats.
    @Published var searchText: String = "" {
        didSet { if searchText != oldValue { reload() } }
    }

    private let dbQueue: DatabaseQueue

    init() {
        dbQueue = Self.makeQueue()
        do {
            try Self.migrator.migrate(dbQueue)
        } catch {
            print("[store] migration failed: \(error)")
        }
        reload()
    }

    // MARK: - Navigation

    func openProject(_ id: UUID) { activeProjectID = id }
    func exitProject() { activeProjectID = nil }

    /// Switch the chat pane to a brand-new, unsaved conversation (scoped to the
    /// current project when one is open).
    func startNewChat() { activeConversationID = nil }

    // MARK: - Conversation mutations

    /// Insert a new (empty) conversation in the current project scope and return
    /// its id. Called lazily on the first message of a fresh chat.
    func createConversation(title: String) -> UUID {
        let id = UUID()
        let now = Self.epoch()
        let safeTitle = title.isEmpty ? "New Chat" : title
        let projectID = activeProjectID?.uuidString
        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO conversations (id, project_id, title, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [id.uuidString, projectID, safeTitle, now, now])
            }
        } catch {
            print("[store] createConversation failed: \(error)")
        }
        reload()
        return id
    }

    /// Append a message to a conversation and bump its `updated_at`.
    func appendMessage(_ message: Message, to conversationID: UUID) {
        let now = Self.epoch()
        let toolJSON = Self.encodeToolCalls(message.toolCalls)
        do {
            try dbQueue.write { db in
                let nextPos = try Int.fetchOne(db, sql: """
                    SELECT COALESCE(MAX(position), -1) + 1 FROM messages WHERE conversation_id = ?
                    """, arguments: [conversationID.uuidString]) ?? 0
                try db.execute(sql: """
                    INSERT INTO messages (id, conversation_id, role, content, tool_calls_json, created_at, position, model)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        message.id.uuidString, conversationID.uuidString,
                        message.role.rawValue, message.content, toolJSON, now, nextPos, message.model,
                    ])
                try db.execute(sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                               arguments: [now, conversationID.uuidString])
            }
        } catch {
            print("[store] appendMessage failed: \(error)")
        }
        reload()
    }

    /// Give a conversation a custom title. No-op on empty/whitespace input so a
    /// chat never ends up nameless; capped to keep the sidebar tidy.
    func rename(_ conversationID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try dbQueue.write { db in
                try db.execute(sql: "UPDATE conversations SET title = ? WHERE id = ?",
                               arguments: [String(trimmed.prefix(120)), conversationID.uuidString])
            }
        } catch {
            print("[store] rename failed: \(error)")
        }
        reload()
    }

    /// The per-chat model override, or nil if the chat follows the global default.
    func conversationModel(_ conversationID: UUID) -> String? {
        do {
            return try dbQueue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT model_override FROM conversations WHERE id = ?",
                    arguments: [conversationID.uuidString]
                )
            }
        } catch {
            print("[store] conversationModel failed: \(error)")
            return nil
        }
    }

    /// Set (or clear, with nil) a chat's model override. Does not touch updated_at —
    /// picking a model isn't activity, so it shouldn't reorder the sidebar.
    func setConversationModel(_ model: String?, for conversationID: UUID) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "UPDATE conversations SET model_override = ? WHERE id = ?",
                               arguments: [model, conversationID.uuidString])
            }
        } catch {
            print("[store] setConversationModel failed: \(error)")
        }
    }

    /// Move a conversation into a project (or back to independent with nil).
    func moveConversation(_ conversationID: UUID, toProject projectID: UUID?) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "UPDATE conversations SET project_id = ? WHERE id = ?",
                               arguments: [projectID?.uuidString, conversationID.uuidString])
            }
        } catch {
            print("[store] moveConversation failed: \(error)")
        }
        reload()
    }

    /// Delete a conversation and all its messages (FK cascade). Never touches disk
    /// artifacts.
    func delete(_ conversationID: UUID) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM conversations WHERE id = ?",
                               arguments: [conversationID.uuidString])
            }
        } catch {
            print("[store] delete failed: \(error)")
        }
        if activeConversationID == conversationID { activeConversationID = nil }
        reload()
    }

    // MARK: - Project mutations

    /// Create a project: scaffold its folder, insert the row, then enter it with a
    /// fresh chat ready to go.
    @discardableResult
    func createProject(name: String, description: String, folderURL: URL, guidelines: String,
                       color: ProjectColor = .defaultBlue) -> UUID {
        let id = UUID()
        let now = Self.epoch()
        ProjectScaffold.scaffold(projectID: id, name: name, description: description, folder: folderURL, guidelines: guidelines)
        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO projects (id, name, description, folder_path, created_at, archived, color)
                    VALUES (?, ?, ?, ?, ?, 0, ?)
                    """, arguments: [
                        id.uuidString, name,
                        description.isEmpty ? nil : description,
                        folderURL.path, now, color.rawValue,
                    ])
            }
        } catch {
            print("[store] createProject failed: \(error)")
        }
        activeConversationID = nil     // fresh chat in the new project
        activeProjectID = id           // enter it (didSet → reload)
        return id
    }

    /// Update a project's editable metadata (name, description, color). Folder and
    /// guidelines live on disk and are edited directly in the project folder.
    func updateProject(id: UUID, name: String, description: String, color: ProjectColor) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    UPDATE projects SET name = ?, description = ?, color = ? WHERE id = ?
                    """, arguments: [
                        trimmed,
                        description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? nil
                            : description.trimmingCharacters(in: .whitespacesAndNewlines),
                        color.rawValue, id.uuidString,
                    ])
            }
        } catch {
            print("[store] updateProject failed: \(error)")
        }
        reload()
    }

    /// Delete a project. Its chats survive (FK `ON DELETE SET NULL` → they become
    /// independent) and the folder on disk is never touched. (Locked decision.)
    func deleteProject(_ id: UUID) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id.uuidString])
            }
        } catch {
            print("[store] deleteProject failed: \(error)")
        }
        if activeProjectID == id { activeProjectID = nil }
        reload()
    }

    // MARK: - Reads

    /// Filesystem path of the project that owns this conversation, or nil if it's
    /// an independent chat. Sent to the sidecar as `project_dir` so it can read
    /// the folder's `project.toml`/`guidelines.md` and scope tools there.
    func projectFolderPath(forConversation id: UUID) -> String? {
        (try? dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT p.folder_path FROM projects p
                JOIN conversations c ON c.project_id = p.id
                WHERE c.id = ?
                """, arguments: [id.uuidString])
        }) ?? nil
    }

    /// Full message list for a conversation, in order.
    func loadMessages(_ conversationID: UUID) -> [Message] {
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, role, content, tool_calls_json, model
                FROM messages WHERE conversation_id = ? ORDER BY position ASC
                """, arguments: [conversationID.uuidString])
        }) ?? []

        return rows.compactMap { row in
            guard let idString: String = row["id"], let id = UUID(uuidString: idString),
                  let roleString: String = row["role"], let role = Message.Role(rawValue: roleString)
            else { return nil }
            let content: String = row["content"] ?? ""
            let tools = Self.decodeToolCalls(row["tool_calls_json"])
            let model: String? = row["model"]
            return Message(id: id, role: role, content: content, isStreaming: false, toolCalls: tools, model: model)
        }
    }

    /// Recompute all published lists for the current view + search.
    func reload() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchIDs = trimmed.isEmpty ? nil : searchMatchIDs(trimmed)

        conversations = fetchConversations(projectScope: activeProjectID, restrictTo: matchIDs)
        allProjects = fetchAllProjects()
        activeProject = activeProjectID.flatMap { id in allProjects.first { $0.id == id } }

        if activeProjectID == nil {
            let convProjectIDs = matchIDs.map { projectIDs(forConversationIDs: $0) } ?? []
            projects = filterProjects(allProjects, query: trimmed, containingProjectIDs: convProjectIDs)
        } else {
            projects = []
        }
    }

    private func fetchConversations(projectScope: UUID?, restrictTo ids: Set<String>?) -> [ConversationListItem] {
        let whereClause = projectScope == nil ? "c.project_id IS NULL" : "c.project_id = ?"
        let args: StatementArguments = projectScope.map { [$0.uuidString] } ?? []
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id AS id, c.title AS title, c.updated_at AS updated_at,
                       (SELECT m.content FROM messages m
                        WHERE m.conversation_id = c.id AND m.content != ''
                        ORDER BY m.position DESC LIMIT 1) AS preview
                FROM conversations c
                WHERE \(whereClause)
                ORDER BY c.updated_at DESC
                """, arguments: args)
        }) ?? []

        let items = rows.compactMap { row -> ConversationListItem? in
            guard let idString: String = row["id"], let id = UUID(uuidString: idString),
                  let title: String = row["title"] else { return nil }
            let updated: Int = row["updated_at"] ?? 0
            let preview: String = row["preview"] ?? ""
            return ConversationListItem(
                id: id, title: title,
                preview: preview.replacingOccurrences(of: "\n", with: " "),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(updated))
            )
        }
        guard let ids else { return items }
        return items.filter { ids.contains($0.id.uuidString) }
    }

    private func fetchAllProjects() -> [ProjectListItem] {
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id AS id, p.name AS name, p.description AS description,
                       p.folder_path AS folder_path, p.color AS color,
                       (SELECT COUNT(*) FROM conversations c WHERE c.project_id = p.id) AS chat_count
                FROM projects p
                WHERE p.archived = 0
                ORDER BY p.created_at DESC
                """)
        }) ?? []
        return rows.compactMap { row -> ProjectListItem? in
            guard let idString: String = row["id"], let id = UUID(uuidString: idString),
                  let name: String = row["name"] else { return nil }
            let desc: String = row["description"] ?? ""
            let folder: String = row["folder_path"] ?? ""
            let count: Int = row["chat_count"] ?? 0
            let colorRaw: String? = row["color"]
            let color = colorRaw.flatMap { ProjectColor(rawValue: $0) } ?? .defaultBlue
            return ProjectListItem(id: id, name: name, description: desc, folderPath: folder, chatCount: count, color: color)
        }
    }

    private func filterProjects(_ all: [ProjectListItem], query: String, containingProjectIDs: Set<String>) -> [ProjectListItem] {
        guard !query.isEmpty else { return all }
        return all.filter { project in
            project.name.range(of: query, options: .caseInsensitive) != nil
                || containingProjectIDs.contains(project.id.uuidString)
        }
    }

    /// Conversation ids whose title matches (LIKE) or whose any message matches (FTS5),
    /// across *all* conversations regardless of project.
    private func searchMatchIDs(_ query: String) -> Set<String> {
        var ids = Set<String>()
        let fts = Self.ftsQuery(from: query)
        try? dbQueue.read { db in
            if !fts.isEmpty {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT m.conversation_id AS cid
                    FROM messages_fts f JOIN messages m ON m.rowid = f.rowid
                    WHERE messages_fts MATCH ?
                    """, arguments: [fts])
                for row in rows { if let cid: String = row["cid"] { ids.insert(cid) } }
            }
            let titleRows = try Row.fetchAll(db, sql: "SELECT id FROM conversations WHERE title LIKE ?",
                                             arguments: ["%\(query)%"])
            for row in titleRows { if let cid: String = row["id"] { ids.insert(cid) } }
        }
        return ids
    }

    /// The set of project ids that own any of the given conversation ids.
    private func projectIDs(forConversationIDs ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var result = Set<String>()
        try? dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT project_id FROM conversations
                WHERE project_id IS NOT NULL AND id IN (\(placeholders))
                """, arguments: StatementArguments(Array(ids)))
            for row in rows { if let pid: String = row["project_id"] { result.insert(pid) } }
        }
        return result
    }

    // MARK: - Helpers

    private static func epoch() -> Int { Int(Date().timeIntervalSince1970) }

    /// Turn raw search input into a safe FTS5 prefix query — each whitespace token
    /// quoted and prefix-matched, so arbitrary punctuation can't break MATCH syntax.
    private static func ftsQuery(from input: String) -> String {
        let tokens = input
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    private static func encodeToolCalls(_ calls: [ToolCall]) -> String? {
        guard !calls.isEmpty, let data = try? JSONEncoder().encode(calls) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeToolCalls(_ json: String?) -> [ToolCall] {
        guard let json, let data = json.data(using: .utf8),
              let calls = try? JSONDecoder().decode([ToolCall].self, from: data)
        else { return [] }
        return calls
    }

    // MARK: - Setup

    private static func makeQueue() -> DatabaseQueue {
        do {
            let url = databaseURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            return try DatabaseQueue(path: url.path)
        } catch {
            print("[store] on-disk DB unavailable (\(error)); using in-memory")
            return try! DatabaseQueue()
        }
    }

    private static func databaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("LookingGlass", isDirectory: true)
                   .appendingPathComponent("history.db", isDirectory: false)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_schema") { db in
            try db.execute(sql: """
                CREATE TABLE projects (
                    id          TEXT PRIMARY KEY,
                    name        TEXT NOT NULL,
                    description TEXT,
                    folder_path TEXT NOT NULL,
                    created_at  INTEGER NOT NULL,
                    archived    INTEGER NOT NULL DEFAULT 0
                );
                """)
            try db.execute(sql: """
                CREATE TABLE conversations (
                    id         TEXT PRIMARY KEY,
                    project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                    title      TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE TABLE messages (
                    id              TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    role            TEXT NOT NULL,
                    content         TEXT NOT NULL,
                    tool_calls_json TEXT,
                    created_at      INTEGER NOT NULL,
                    position        INTEGER NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_messages_conversation ON messages(conversation_id, position);")
            try db.execute(sql: "CREATE INDEX idx_conversations_project ON conversations(project_id, updated_at);")

            // FTS5 over message content (external-content table synced by triggers).
            try db.execute(sql: """
                CREATE VIRTUAL TABLE messages_fts USING fts5(
                    content, content='messages', content_rowid='rowid'
                );
                """)
            try db.execute(sql: """
                CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
                    INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, new.content);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, content) VALUES('delete', old.rowid, old.content);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, content) VALUES('delete', old.rowid, old.content);
                    INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, new.content);
                END;
                """)
        }
        migrator.registerMigration("v2_project_color") { db in
            try db.execute(sql: "ALTER TABLE projects ADD COLUMN color TEXT")
        }
        // Per-message resolved model (diagnostic): which model produced each turn.
        // Nullable — user turns and pre-v3 history stay NULL. Captures mid-conversation
        // model switches since it's stamped per assistant message, not per conversation.
        //
        // foreignKeyChecks: .immediate — a plain ADD COLUMN creates no new FK violations,
        // but the default .deferred mode runs a FULL-TABLE foreign_key_check at commit,
        // which aborts the whole migrator if any pre-existing orphan row exists (e.g. a
        // message whose conversation was deleted while FKs were off). That would strand a
        // DB at v2 and block every later migration. .immediate only enforces FKs for rows
        // this migration touches (none), so it's safe here and on any column-add. Both
        // migrations are column-adds, never table recreations, so .immediate is valid.
        migrator.registerMigration("v3_message_model", foreignKeyChecks: .immediate) { db in
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN model TEXT")
        }
        // Per-conversation model override (input-bar switcher). Nullable: NULL = follow
        // the global default. Non-NULL = sticky pick for this chat, survives reopen.
        migrator.registerMigration("v4_conversation_model", foreignKeyChecks: .immediate) { db in
            try db.execute(sql: "ALTER TABLE conversations ADD COLUMN model_override TEXT")
        }
        // Hygiene: purge orphaned messages (conversation deleted while FKs were off) so
        // PRAGMA foreign_key_check is clean again and they stop polluting the FTS index.
        // Deletes only unreachable rows — loadMessages already filters by conversation_id.
        migrator.registerMigration("v5_purge_orphan_messages") { db in
            try db.execute(sql: """
                DELETE FROM messages
                WHERE conversation_id NOT IN (SELECT id FROM conversations)
                """)
        }
        return migrator
    }
}
