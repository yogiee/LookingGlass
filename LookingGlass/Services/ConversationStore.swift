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
    /// in project view. Newest first, honoring `searchText`. This is the pristine
    /// keyword (FTS + title) result — semantic search never touches it.
    @Published private(set) var conversations: [ConversationListItem] = []

    /// Semantic-only matches for the active search — conversations whose *meaning*
    /// matches but which the keyword search missed. Rendered as a separate, clearly
    /// labelled "Related" section beneath `conversations`, never blended in. Empty
    /// when idle, when meaning-based search is off, or when nothing clears threshold.
    @Published private(set) var relatedConversations: [ConversationListItem] = []

    /// True while the async semantic pass for the current search is in flight — drives
    /// a small "Finding related…" indicator so search never feels like it hung.
    @Published private(set) var isSearchingRelated = false

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

    /// In-flight semantic ranking for the current search; cancelled when the search
    /// text changes so a fast typist never sees a stale result overwrite a newer one.
    private var rankTask: Task<Void, Never>?

    /// Minimum cosine for a conversation to appear in the "Related" section.
    /// Calibrated 2026-07-21 on real history (39 convs, prefixed conversation-level
    /// vectors): genuine descriptive wins land ~0.35–0.58 ("pictures of a dog" → beagle
    /// chats 0.42), noise floor ~0.11–0.25. 0.35 catches the wins, stays quiet on noise.
    private static let semanticThreshold: Float = 0.35
    /// Cap on Related results — a short, high-signal list, not a flood.
    private static let semanticNeighborCap = 6

    /// Whether meaning-based (semantic) search is enabled. Off ⇒ pure FTS, and the
    /// embedding/backfill work never runs. **Defaults OFF (2026-07-21):** the raw-content
    /// embedding only half-works — great for content-rich chats, blind to thin/roleplay
    /// ones (concepts like "Superhero"/"Butler" miss). Plumbing kept; re-enable once the
    /// Feature-B @Generable *summary* path lands (embed a distilled summary, not raw text).
    private static var semanticEnabled: Bool {
        UserDefaults.standard.object(forKey: "semanticSearchEnabled")
            .map { ($0 as? Bool) ?? false } ?? false
    }

    init() {
        dbQueue = Self.makeQueue()
        do {
            try Self.migrator.migrate(dbQueue)
        } catch {
            print("[store] migration failed: \(error)")
        }
        reload()
        backfillEmbeddings()   // embed any history that predates semantic search
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
        scheduleConversationEmbedding(conversationID)
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
        scheduleConversationEmbedding(conversationID)   // title is part of the gist
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

        // The keyword paint above (`conversations`) stays pristine. When searching with
        // meaning-based search on, an async pass fills the SEPARATE `relatedConversations`
        // section with semantic-only matches. Idle / disabled ⇒ no Related section.
        rankTask?.cancel()
        if trimmed.isEmpty || !Self.semanticEnabled {
            rankTask = nil
            isSearchingRelated = false
            if !relatedConversations.isEmpty { relatedConversations = [] }
        } else {
            let keywordIDs = matchIDs ?? []
            let scope = activeProjectID
            isSearchingRelated = true
            rankTask = Task { [weak self] in
                await self?.computeRelated(query: trimmed, keywordIDs: keywordIDs, scope: scope)
            }
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

    // MARK: - Semantic embeddings (conversation-level)

    /// Recompute this conversation's semantic embedding in the background. The gist =
    /// title + the user's messages (topic-bearing text); an unchanged gist is skipped
    /// via a content hash. No-op when meaning-based search is off.
    private func scheduleConversationEmbedding(_ conversationID: UUID) {
        guard Self.semanticEnabled else { return }
        let queue = dbQueue
        Task.detached(priority: .utility) {
            await Self.refreshConversationEmbedding(dbQueue: queue, conversationID: conversationID)
        }
    }

    /// Embed every conversation whose gist changed or was never embedded. Background,
    /// off init; resumes across launches (the tag/hash check skips current rows).
    func backfillEmbeddings() {
        guard Self.semanticEnabled else { return }
        let queue = dbQueue
        Task.detached(priority: .background) {
            guard await SemanticSearchService.shared.isAvailable else { return }
            for id in Self.allConversationIDs(dbQueue: queue) {
                await Self.refreshConversationEmbedding(dbQueue: queue, conversationID: id)
            }
        }
    }

    /// The heavy path, fully off the main actor: read the gist, skip if the stored
    /// vector is already current (same tag + same content hash), else embed (as a
    /// retrieval document) and store.
    nonisolated private static func refreshConversationEmbedding(dbQueue: DatabaseQueue,
                                                                 conversationID: UUID) async {
        guard await SemanticSearchService.shared.isAvailable,
              let gist = conversationGist(dbQueue: dbQueue, conversationID: conversationID)
        else { return }
        let hash = stableHash(gist.title + "\u{01}" + gist.text)
        let tag = await SemanticSearchService.shared.activeTag
        if let stored = storedEmbeddingMeta(dbQueue: dbQueue, conversationID: conversationID),
           stored.tag == tag, stored.hash == hash { return }   // already current
        guard let result = await SemanticSearchService.shared.embedConversation(title: gist.title, text: gist.text)
        else { return }
        storeConversationEmbedding(dbQueue: dbQueue, conversationID: conversationID,
                                   vector: result.vector, tag: result.tag, hash: hash)
    }

    /// A conversation's topic-bearing gist: title + the user's messages (the user's
    /// framing carries the subject; assistant boilerplate is left out to avoid the
    /// "Hey Alice"/"Sure thing!" noise). nil when there's nothing to embed yet.
    nonisolated private static func conversationGist(dbQueue: DatabaseQueue,
                                                     conversationID: UUID) -> (title: String, text: String)? {
        var title = ""
        var userText = ""
        try? dbQueue.read { db in
            title = (try String.fetchOne(db, sql: "SELECT title FROM conversations WHERE id = ?",
                                         arguments: [conversationID.uuidString])) ?? ""
            let msgs = try String.fetchAll(db, sql: """
                SELECT content FROM messages
                WHERE conversation_id = ? AND role = 'user' AND content != ''
                ORDER BY position ASC
                """, arguments: [conversationID.uuidString])
            userText = msgs.joined(separator: "\n")
        }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = String(userText.prefix(2000))
        if t.isEmpty && text.isEmpty { return nil }
        return (t, text)
    }

    nonisolated private static func storeConversationEmbedding(dbQueue: DatabaseQueue, conversationID: UUID,
                                                               vector: [Float], tag: String, hash: Int64) {
        let blob = SemanticSearchService.data(from: vector)
        let now = Int(Date().timeIntervalSince1970)
        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT OR REPLACE INTO conversation_embeddings
                        (conversation_id, vector, dim, model_tag, content_hash, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [conversationID.uuidString, blob, vector.count, tag, hash, now])
            }
        } catch {
            print("[store] storeConversationEmbedding failed: \(error)")
        }
    }

    nonisolated private static func storedEmbeddingMeta(dbQueue: DatabaseQueue,
                                                        conversationID: UUID) -> (tag: String, hash: Int64)? {
        (try? dbQueue.read { db -> (String, Int64)? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT model_tag, content_hash FROM conversation_embeddings WHERE conversation_id = ?
                """, arguments: [conversationID.uuidString]) else { return nil }
            let tag: String = row["model_tag"] ?? ""
            let hash: Int64 = row["content_hash"] ?? 0
            return (tag, hash)
        }) ?? nil
    }

    nonisolated private static func allConversationIDs(dbQueue: DatabaseQueue) -> [UUID] {
        let rows = (try? dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM conversations")
        }) ?? []
        return rows.compactMap { UUID(uuidString: $0) }
    }

    /// FNV-1a — a *stable* hash (Swift's `hashValue` is per-run randomized and would
    /// force a re-embed every launch).
    nonisolated private static func stableHash(_ s: String) -> Int64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return Int64(bitPattern: h)
    }

    // MARK: - Semantic search (Related section)

    /// Fill `relatedConversations` with semantic-only matches: embed the query
    /// (retrieval-prefixed), scan conversation vectors OFF the main thread, keep the
    /// ones the keyword search missed that clear threshold, capped short. Clears
    /// Related when embeddings are unavailable; leaves it untouched if the search
    /// already moved on (a newer pass will set it).
    private func computeRelated(query: String, keywordIDs: Set<String>, scope: UUID?) async {
        guard let qvec = await SemanticSearchService.shared.embedQuery(query) else {
            isSearchingRelated = false
            if !relatedConversations.isEmpty { relatedConversations = [] }
            return
        }
        if Task.isCancelled { return }

        let queue = dbQueue
        let tag = await SemanticSearchService.shared.activeTag
        let scored = await Task.detached(priority: .userInitiated) {
            Self.rankConversationVectors(dbQueue: queue, queryVector: qvec, tag: tag, scope: scope)
        }.value
        if Task.isCancelled { return }
        guard query == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        // Semantic-only (drop keyword hits — they're in the main list), ≥ threshold, capped.
        let hits = scored
            .filter { !keywordIDs.contains($0.id) && $0.score >= Self.semanticThreshold }
            .sorted { $0.score > $1.score }
            .prefix(Self.semanticNeighborCap)
        let scoreByID = Dictionary(hits.map { ($0.id, $0.score) }, uniquingKeysWith: { a, _ in a })
        let items = fetchConversations(projectScope: scope, restrictTo: Set(scoreByID.keys))
        let ordered = items.sorted { (scoreByID[$0.id.uuidString] ?? -1) > (scoreByID[$1.id.uuidString] ?? -1) }

        #if DEBUG
        // τ-tuning aid: print cosine·title for the Related candidates from real queries.
        let dbg = ordered.prefix(8)
            .map { String(format: "%.3f·%@", scoreByID[$0.id.uuidString] ?? -1, String($0.title.prefix(22))) }
            .joined(separator: " | ")
        print("[semsearch] related τ=\(Self.semanticThreshold) of \(scored.count) scanned → \(dbg)")
        #endif

        relatedConversations = ordered
        isSearchingRelated = false
    }

    /// Cosine of the query against every in-scope conversation vector (active tag).
    /// `nonisolated` + `dbQueue` passed in ⇒ runs off the main thread.
    nonisolated private static func rankConversationVectors(dbQueue: DatabaseQueue, queryVector: [Float],
                                                            tag: String, scope: UUID?) -> [(id: String, score: Float)] {
        let whereClause = scope == nil ? "c.project_id IS NULL" : "c.project_id = ?"
        let args: StatementArguments = scope.map { [tag, $0.uuidString] } ?? [tag]
        var out: [(id: String, score: Float)] = []
        try? dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.conversation_id AS cid, e.vector AS vec
                FROM conversation_embeddings e
                JOIN conversations c ON c.id = e.conversation_id
                WHERE e.model_tag = ? AND \(whereClause)
                """, arguments: args)
            for row in rows {
                guard let cid: String = row["cid"], let data: Data = row["vec"] else { continue }
                let v = SemanticSearchService.vector(from: data)
                guard v.count == queryVector.count else { continue }
                out.append((cid, SemanticSearchService.cosine(queryVector, v)))
            }
        }
        return out
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
        // Semantic-search vectors: one on-device embedding per message, stored as a
        // Float32 BLOB alongside a `model_tag` (the source that produced it) so a
        // model change can invalidate + re-embed stale rows. Separate table (not a
        // messages column) keeps normal message reads lean and makes backfill/re-embed
        // a clean upsert. FK-cascades with the message; .immediate FK-check for the
        // same reason as v3/v4 — this migration touches no existing rows.
        migrator.registerMigration("v6_message_embeddings", foreignKeyChecks: .immediate) { db in
            try db.execute(sql: """
                CREATE TABLE message_embeddings (
                    message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    vector     BLOB    NOT NULL,
                    dim        INTEGER NOT NULL,
                    model_tag  TEXT    NOT NULL,
                    created_at INTEGER NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_message_embeddings_tag ON message_embeddings(model_tag);")
        }
        // Semantic search moved from per-message to per-conversation embeddings: a chat
        // now matches on its overall topic (title + user messages), not one lucky message
        // — which was the source of the muddy results. Drop the v6 per-message table and
        // store one vector per conversation, with a content hash to skip unchanged re-embeds.
        // .immediate FK-check (touches no existing rows).
        migrator.registerMigration("v7_conversation_embeddings", foreignKeyChecks: .immediate) { db in
            try db.execute(sql: "DROP TABLE IF EXISTS message_embeddings;")
            try db.execute(sql: """
                CREATE TABLE conversation_embeddings (
                    conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
                    vector       BLOB    NOT NULL,
                    dim          INTEGER NOT NULL,
                    model_tag    TEXT    NOT NULL,
                    content_hash INTEGER NOT NULL,
                    updated_at   INTEGER NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_conversation_embeddings_tag ON conversation_embeddings(model_tag);")
        }
        return migrator
    }
}
