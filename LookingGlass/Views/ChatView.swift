import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isStreaming = false
    @Published var inputText = ""

    // Research mode state
    @Published var researchMode = false          // user toggle — resets after each send
    @Published var isResearching = false         // active research run in progress
    @Published var researchStatus: String? = nil // current phase label
    @Published var researchReportPath: String? = nil // set when report is saved

    private var researchSearchCount = 0
    private var researchReadCount = 0

    /// The conversation currently mirrored in `messages`. Kept in sync with the
    /// store's `activeConversationID`; `nil` = an unsaved fresh chat.
    private(set) var loadedConversationID: UUID?

    var toolCallStore: ToolCallStore?

    private let client = SidecarClient()
    private var streamTask: Task<Void, Never>?

    /// Swap the chat pane to a different conversation (or a blank one for `nil`).
    func load(_ conversationID: UUID?, store: ConversationStore) {
        streamTask?.cancel()
        isStreaming = false
        loadedConversationID = conversationID
        messages = conversationID.map { store.loadMessages($0) } ?? []
        // Restore the report path if a file_write tool call was saved and the file still exists.
        researchReportPath = messages
            .flatMap(\.toolCalls)
            .filter { $0.tool == "file_write" && $0.isComplete }
            .compactMap { Self.extractResearchPath(from: $0.result) }
            .last(where: { FileManager.default.fileExists(atPath: $0) })
        researchStatus = researchReportPath != nil ? "Report ready" : nil
    }

    func send(model: String?, ollamaHost: String, enabledTools: [String]?, systemPrompt: String?, userName: String?, mcpHintsEnabled: [String: Bool]? = nil, researchMode: Bool = false, store: ConversationStore, attachmentPath: String? = nil,
              source: Message.Source = .typed, dictationOriginal: String? = nil,
              voiceMode: Bool = false) {
        let typed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if let path = attachmentPath {
            text = typed.isEmpty ? "[Image: \(path)]" : "[Image: \(path)]\n\n\(typed)"
        } else {
            text = typed
        }
        guard !text.isEmpty, !isStreaming else { return }

        inputText = ""
        let userMessage = Message(role: .user, content: text,
                                  source: source, dictationOriginal: dictationOriginal)
        messages.append(userMessage)

        // Ensure a persisted conversation exists, then save the user's turn.
        // Setting loadedConversationID *before* activeConversationID means the
        // view's onChange guard treats this as "already loaded" and won't reload.
        let conversationID: UUID
        let isFirstTurn: Bool
        if let active = loadedConversationID {
            conversationID = active
            isFirstTurn = false
        } else {
            let newID = store.createConversation(title: Self.deriveTitle(text))
            loadedConversationID = newID
            store.activeConversationID = newID
            conversationID = newID
            isFirstTurn = true
        }
        store.appendMessage(userMessage, to: conversationID)

        runTurn(history: Array(messages), model: model, ollamaHost: ollamaHost,
                enabledTools: enabledTools, systemPrompt: systemPrompt, userName: userName,
                mcpHintsEnabled: mcpHintsEnabled, researchMode: researchMode, specialistMode: false,
                voiceMode: voiceMode,
                conversationID: conversationID, isFirstTurn: isFirstTurn, titleSeed: text, store: store)
    }

    /// "Consult the big model": re-run the last user turn on the specialist (cloud)
    /// model and append a new, cloud-tagged assistant turn. The local answer is kept
    /// above it — a labeled local↔cloud pair on the same prompt. Consent = the tap;
    /// nothing leaves the machine until the user invokes this.
    func escalate(ollamaHost: String, enabledTools: [String]?, systemPrompt: String?,
                  userName: String?, mcpHintsEnabled: [String: Bool]? = nil,
                  store: ConversationStore) {
        guard !isStreaming else { return }
        guard let conversationID = loadedConversationID else { return }
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        // History through the last USER message — exclude the local answer so the
        // specialist responds to the question fresh, not to Alice's take.
        let history = Array(messages.prefix(through: lastUserIdx))
        let seed = messages[lastUserIdx].content
        runTurn(history: history, model: nil, ollamaHost: ollamaHost,
                enabledTools: enabledTools, systemPrompt: systemPrompt, userName: userName,
                mcpHintsEnabled: mcpHintsEnabled, researchMode: false, specialistMode: true,
                conversationID: conversationID, isFirstTurn: false, titleSeed: seed, store: store)
    }

    /// Append a streaming assistant placeholder, stream the turn from the sidecar, and
    /// persist it. Shared by `send` (fresh user turn) and `escalate` (specialist re-run).
    private func runTurn(history: [Message], model: String?, ollamaHost: String,
                         enabledTools: [String]?, systemPrompt: String?, userName: String?,
                         mcpHintsEnabled: [String: Bool]?, researchMode: Bool, specialistMode: Bool,
                         voiceMode: Bool = false,
                         conversationID: UUID, isFirstTurn: Bool, titleSeed: String,
                         store: ConversationStore) {
        messages.append(Message(role: .assistant, content: "", isStreaming: true))
        isStreaming = true

        // Research state — reset per-run so each run starts clean
        isResearching = researchMode
        researchStatus = researchMode ? "Starting research..." : nil
        researchReportPath = nil
        researchSearchCount = 0
        researchReadCount = 0
        self.researchMode = false  // reset toggle; user re-enables for next run

        // Where this conversation lives — sent so the sidecar scopes tools and
        // reads project.toml/guidelines.md. nil for independent chats.
        let projectDir = store.projectFolderPath(forConversation: conversationID)
        // User's configured save root for independent chats (Settings → System).
        // Empty → sidecar uses its ~/Documents/LookingGlass default. Ignored when
        // in a project (the project folder wins).
        let filesRoot = UserDefaults.standard.string(forKey: "filesRoot")
        // Alice's ambient context (location + weather from macOS). Captured on the main actor here;
        // the sidecar folds it into her "## Your environment" block. nil when location isn't granted.
        let environment = AmbientContextService.shared.environmentDict

        streamTask = Task {
            defer {
                if let idx = messages.indices.last { messages[idx].isStreaming = false }
                isStreaming = false
                isResearching = false
                if researchReportPath == nil { researchStatus = nil }
                // Persist the completed assistant turn (content + any tool calls).
                if let idx = messages.indices.last {
                    let assistant = messages[idx]
                    if !assistant.content.isEmpty || !assistant.toolCalls.isEmpty {
                        store.appendMessage(assistant, to: conversationID)
                    }
                }
            }
            do {
                for try await event in client.stream(
                    // System notices are UI-only — never sent to the model.
                    messages: history.filter { $0.role != .system },
                    model: model,
                    ollamaHost: ollamaHost,
                    enabledTools: enabledTools,
                    systemPrompt: systemPrompt,
                    projectDir: projectDir,
                    filesRoot: filesRoot,
                    userName: userName,
                    mcpHintsEnabled: mcpHintsEnabled,
                    researchMode: researchMode,
                    specialistMode: specialistMode,
                    voiceMode: voiceMode,
                    environment: environment
                ) {
                    guard !Task.isCancelled else { break }
                    apply(event)
                }
                // After the first assistant reply, replace the derived title with an
                // FM-generated one — more descriptive than the raw first line of user input.
                if isFirstTurn, !Task.isCancelled,
                   let assistantContent = messages.last.map({ $0.role == .assistant ? $0.content : "" }),
                   !assistantContent.isEmpty {
                    // Feed the FM a marker-free prompt — a raw file path can trip its guardrails
                    // (→ nil → no rename, leaving the ugly "[Image: …]" title).
                    if let fmTitle = await AppleIntelligenceService.shared.generateConversationTitle(
                        userMessage: ImagePathScanner.stripMarkers(titleSeed), assistantReply: assistantContent) {
                        store.rename(conversationID, to: fmTitle)
                    }
                }
            } catch {
                if let idx = messages.indices.last, messages[idx].content.isEmpty,
                   messages[idx].toolCalls.isEmpty {
                    messages[idx].content = error.localizedDescription
                }
            }
        }
    }

    /// Conversation title from the first user message — first line, trimmed, capped. Strips any
    /// `[Image: /path]` markers first so an image-drop chat doesn't title itself with a file path
    /// (falls back to the prose, or "New Chat" for an image-only message).
    private static func deriveTitle(_ text: String) -> String {
        let stripped = ImagePathScanner.stripMarkers(text)
        let firstLine = stripped.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? stripped
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "New Chat" : String(trimmed.prefix(60))
    }

    private func apply(_ event: ChatEvent) {
        guard let idx = messages.indices.last else { return }
        switch event {
        case .contentDelta(let chunk):
            messages[idx].content += chunk
        case .toolCallStart(let id, let tool, let argsJSON):
            messages[idx].toolCalls.append(ToolCall(id: id, tool: tool, argsJSON: argsJSON))
            toolCallStore?.recordStart(id: id, tool: tool, argsJSON: argsJSON, conversationId: loadedConversationID)
            // Update research progress banner from tool events — no sidecar changes needed
            if isResearching {
                switch tool {
                case "use_skill":   researchStatus = "Framing research plan..."
                case "web_search":
                    researchSearchCount += 1
                    researchStatus = "Searching the web (\(researchSearchCount))..."
                case "http_request":
                    researchReadCount += 1
                    researchStatus = "Reading sources (\(researchReadCount))..."
                case "file_write":  researchStatus = "Saving report..."
                default: break
                }
            }
        case .toolCallResult(let id, let success, let result, let latencyMs):
            if let tcIdx = messages[idx].toolCalls.firstIndex(where: { $0.id == id }) {
                // Truncate before storing — full page reads can be 100KB; keeping them
                // in memory bloats the history sent on subsequent turns and can freeze the UI.
                let stored = result.count > 3_000
                    ? result.prefix(3_000) + "\n…[truncated for display]"
                    : result
                messages[idx].toolCalls[tcIdx].result = String(stored)
                messages[idx].toolCalls[tcIdx].success = success
                messages[idx].toolCalls[tcIdx].latencyMs = latencyMs
                messages[idx].toolCalls[tcIdx].isComplete = true
                // Detect saved research report by matching file_write result to research/*.md
                // Scan original result (pre-truncation) — path is always in the first line.
                if isResearching, success,
                   messages[idx].toolCalls[tcIdx].tool == "file_write",
                   let path = Self.extractResearchPath(from: result) {
                    researchReportPath = path
                    researchStatus = "Report ready"
                }
            }
            toolCallStore?.recordResult(id: id, success: success, result: result)
        case .messageEnd(let model, _, _):
            // Stamp the resolved model on this turn so it persists (and survives a
            // mid-conversation model switch — each assistant turn records its own).
            if let model { messages[idx].model = model }
        case .error(let msg):
            if messages[idx].content.isEmpty {
                messages[idx].content = msg.isEmpty ? "Something went wrong." : msg
            }
        }
    }

    func cancelStream() { streamTask?.cancel() }

    /// Extracts a research report path from a file_write tool result string.
    /// Result format: "Wrote /path/to/research/topic.md (N chars)"
    private static func extractResearchPath(from result: String) -> String? {
        result.split(separator: " ").first(where: {
            $0.contains("/research/") && $0.hasSuffix(".md")
        }).map(String.init)
    }
}

struct ChatView: View {
    @EnvironmentObject private var store: ConversationStore
    @EnvironmentObject private var toolCallStore: ToolCallStore
    @EnvironmentObject private var reportPanel: ReportPanelState
    @EnvironmentObject private var catalog: ModelCatalog
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var inputController = ChatInputController()

    /// This chat's model override (input-bar switcher). nil = follow the global default.
    /// Loaded from / persisted to the conversation row; held in @State while a fresh
    /// chat has no row yet (persisted on first send).
    @State private var chatModelOverride: String?

    /// The active conversation's project folder (nil = independent chat) — gates
    /// the per-message "Save to memory" action on assistant bubbles.
    private var activeProjectDir: String? {
        guard let cid = store.activeConversationID else { return nil }
        return store.projectFolderPath(forConversation: cid)
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var fontSize
    @Environment(\.chatLineHeight) private var lineHeight

    @AppStorage("selectedModel") private var selectedModel = ""   // "" = Auto (sidecar resolves)
    @AppStorage("ocrPastedImages") private var ocrPastedImages = true  // paste text-image → OCR, skip VLM
    @AppStorage("userName") private var userName = ""
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"
    @AppStorage("enabledTools") private var enabledToolsJSON = ""
    @AppStorage("systemPrompt") private var systemPrompt = ""
    @AppStorage("chatFontChoice") private var chatFontChoiceRaw = ChatFontChoice.system.rawValue
    @AppStorage("mcpHintsEnabledJSON") private var mcpHintsEnabledJSON = "{}"

    private var fontChoice: ChatFontChoice { ChatFontChoice(rawValue: chatFontChoiceRaw) ?? .system }

    @State private var inputHeight: CGFloat = 22
    @State private var inputFocused = false
    @State private var pendingAttachment: URL?
    @State private var pendingImage: NSImage?
    @State private var isRecognizingText = false   // brief OCR pass on a freshly pasted image
    @State private var isDropTargeted = false      // image drag hovering the input bar

    private var inputMinHeight: CGFloat { fontSize + 8 }
    private var inputMaxHeight: CGFloat { (fontSize + 8) * 7 }
    // Reserve scroll space for the whole input region (text field + bottom bar + padding)
    private var inputReserve: CGFloat { inputHeight + 84 }

    /// Dim level for input-bar controls while a turn runs — everything except STOP
    /// is disabled, and this makes the lock visible at a glance.
    private let lockedOpacity = 0.45
    /// Voice input. Observed at this level (not only in the leaf button) because
    /// the composer shows a live transcript strip while the mic is open.
    @ObservedObject private var speechInput = SpeechInputService.shared
    /// Observed so the spectrograph can dim while Alice is talking — the mic is
    /// muted then, and a flat line needs to look deliberate.
    @ObservedObject private var speechOutput = SpeechOutputService.shared

    /// Voice mode is *armed*, not listening. The mic stays shut until SPACE
    /// says otherwise — perpetual listening meant a phone call in the same room
    /// kept feeding the transcript.
    @State private var voiceModeArmed = false
    @StateObject private var voiceKeys = VoiceKeyMonitor()

    /// What the composer is currently for. Arming is explicit state; a bare
    /// mic-hold (quick dictation without entering voice mode) still reads as
    /// voice for tint and display purposes, but never narrates.
    private var composerMode: ComposerMode {
        if voiceModeArmed { return .voice }
        return speechInput.state != .idle ? .voiceHeld : .text
    }
    /// The raw transcript of a dictation held back for review, kept so that
    /// whatever Yogi changes before sending can be read as a correction.
    @State private var dictationUnderReview: String?
    /// Words the recogniser flagged, named in the review strip so a mis-tuned
    /// confidence floor is visible rather than silent.
    @State private var uncertainWords: [String] = []
    /// Set when a turn is sent from latched voice mode, so the reply gets read
    /// back. Consumed on stream end — a held-mic aside never narrates.
    @State private var narrateNextReply = false
    /// The editor had focus when the lock engaged → restore it when the turn ends
    /// (never steals focus from another field, e.g. Settings → System Prompt).
    @State private var refocusAfterStream = false

    var body: some View {
        ZStack(alignment: .bottom) {
            messageList
            // Alice watches from the center until the first chat loads, with a comic
            // speech bubble (tap to re-roll). Hit-testing stays ON so the bubble is
            // tappable; only the bubble carries a gesture, so empty-area taps do nothing.
            if viewModel.messages.isEmpty {
                AliceEmptyState()
                    .transition(.opacity)
            }
            // Research progress banner + input bar stacked so banner sits flush above
            VStack(spacing: 0) {
                if viewModel.isResearching, let status = viewModel.researchStatus {
                    ResearchProgressBanner(status: status)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                floatingInputBar
            }
        }
        .animation(.easeInOut(duration: 0.4), value: viewModel.messages.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isResearching)
        // Sidebar selection (or New Chat) drives which conversation is shown.
        // Guard against the self-triggered change when send() creates a new one.
        .onChange(of: store.activeConversationID) { _, newID in
            if newID != viewModel.loadedConversationID {
                reportPanel.dismiss()
                viewModel.load(newID, store: store)
                chatModelOverride = newID.flatMap { store.conversationModel($0) }
                reconcileModelOverride()
            }
        }
        // Re-run the stale-model guard once the catalog arrives (covers the launch race
        // where a chat loads before /models has responded).
        .onChange(of: catalog.models) { _, _ in reconcileModelOverride() }
        // Input lock lifecycle: remember whether the editor had focus when the turn
        // started, and hand focus back when it ends so typing can resume immediately.
        // Read the reply back when the turn came from latched voice mode.
        // Waits for the stream to finish rather than speaking as tokens arrive:
        // sentence-buffered narration is its own problem, and a half-formed
        // sentence read aloud is worse than a beat of silence.
        .onChange(of: viewModel.isStreaming) { _, streaming in
            guard !streaming, narrateNextReply else { return }
            narrateNextReply = false
            // Voice mode doesn't override the Read-aloud setting: if speech
            // output is switched off, entering voice mode shouldn't start
            // producing audio the user turned off elsewhere.
            guard speechOutput.isEnabled else { return }
            guard let reply = viewModel.messages.last,
                  reply.role == .assistant, !reply.content.isEmpty else { return }
            speechOutput.speak(reply.content, id: reply.id.uuidString)
        }
        // Half-duplex, in one place: the mic is deaf for exactly as long as
        // Alice has the floor — thinking as well as talking.
        .onChange(of: aliceHasTheFloor) { _, busy in
            speechInput.setMuted(busy)
        }
        .onChange(of: viewModel.isStreaming) { _, streaming in
            if streaming {
                refocusAfterStream = inputFocused
            } else if refocusAfterStream {
                refocusAfterStream = false
                inputController.focus()
            }
        }
        // SPACE drives capture while voice mode is armed. Gated so it never
        // swallows a space that belongs to typing — including the review field
        // a flagged transcript drops into.
        .onAppear {
            voiceKeys.isActive = { voiceModeArmed && uncertainWords.isEmpty && !viewModel.isStreaming }
            voiceKeys.onHoldBegan = { Task { await speechInput.start() } }
            voiceKeys.onHoldEnded = {
                Task {
                    let utterance = await speechInput.stop()
                    deliver(utterance, narrate: true)
                }
            }
            voiceKeys.onDoubleTap = {
                if speechInput.isListening {
                    Task {
                        let utterance = await speechInput.stop()
                        deliver(utterance, narrate: true)
                    }
                } else {
                    Task { await speechInput.start() }
                }
            }
            voiceKeys.install()
        }
        .onDisappear { voiceKeys.remove() }
        .task {
            viewModel.toolCallStore = toolCallStore
            chatModelOverride = store.activeConversationID.flatMap { store.conversationModel($0) }
            // Bias dictation toward the proper nouns Yogi actually types. Cached
            // behind a TTL, so calling this per appearance is cheap.
            await speechInput.refreshVocabulary(from: store)
        }
    }

    /// The model this chat will use: its own override, else the global default
    /// (`selectedModel`; "" ⇒ nil ⇒ sidecar Auto).
    private var effectiveModel: String? {
        chatModelOverride ?? (selectedModel.isEmpty ? nil : selectedModel)
    }

    /// Guard B: if the open chat's override points at a model that's no longer installed,
    /// drop the override and record the switch in history so it's visible on reopen.
    private func reconcileModelOverride() {
        guard catalog.loaded,
              let cid = viewModel.loadedConversationID,
              let stale = chatModelOverride,
              !catalog.contains(stale)
        else { return }
        chatModelOverride = nil
        store.setConversationModel(nil, for: cid)
        let fallback = selectedModel.isEmpty ? "the default" : selectedModel
        let notice = Message(
            role: .system,
            content: "⚠️ Model “\(stale)” is no longer installed — this chat switched to \(fallback)."
        )
        // Avoid duplicate notices if the guard fires twice (load + catalog arrival).
        if viewModel.messages.last?.content != notice.content {
            viewModel.messages.append(notice)
            store.appendMessage(notice, to: cid)
        }
    }

    private func submit(source: Message.Source = .typed) {
        // A transcript held back for review and then sent is `.corrected`, not
        // `.typed` — machine output a human verified. Keeping the pre-edit text
        // alongside it is what makes it analysable later: a correction only
        // means something next to what it corrected.
        var provenance = source
        var original: String?
        if let pending = dictationUnderReview {
            dictationUnderReview = nil
            uncertainWords = []
            provenance = .corrected
            original = pending
            let diff = SpokenVocabulary.differences(from: pending, to: viewModel.inputText)
            speechInput.suppress(diff.suppressed)
            speechInput.learn(diff.learned)
        }
        let attachment = pendingAttachment
        pendingAttachment = nil
        pendingImage = nil
        viewModel.send(
            model: effectiveModel,
            ollamaHost: ollamaHost,
            enabledTools: decodedEnabledTools(),
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            userName: userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : userName,
            mcpHintsEnabled: decodedMcpHintsEnabled(),
            researchMode: viewModel.researchMode,
            store: store,
            attachmentPath: attachment?.path,
            source: provenance,
            dictationOriginal: original,
            // Tell Alice this one will be heard, so she writes for the ear and
            // fences anything screen-only. `narrateNextReply` is already set by
            // `deliver` before it calls this.
            voiceMode: narrateNextReply
        )
        // send() may have just created the conversation row — persist a pending override.
        if let override = chatModelOverride, let cid = viewModel.loadedConversationID {
            store.setConversationModel(override, for: cid)
        }
    }

    /// Apply an input-bar switcher pick: nil clears the override (→ global default).
    /// Persists immediately when the chat already has a row.
    private func selectChatModel(_ model: String?) {
        chatModelOverride = model
        if let cid = viewModel.loadedConversationID {
            store.setConversationModel(model, for: cid)
        }
    }

    /// "Consult the big model" on the latest answer — escalate to the cloud specialist.
    private func consult() {
        viewModel.escalate(
            ollamaHost: ollamaHost,
            enabledTools: decodedEnabledTools(),
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            userName: userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : userName,
            mcpHintsEnabled: decodedMcpHintsEnabled(),
            store: store
        )
    }

    private func handleImagePaste(_ image: NSImage) {
        // OCR fast-path (WORKSPACE/apple-native/01-imaging-and-vision.md §A): if the paste is
        // really just text, read it on-device with Vision and drop it into the input — no image
        // attachment, so no [Image:] marker and no describe_image VLM round-trip. Ambiguous /
        // non-text images (and the toggle-off case) fall through to the VLM path unchanged.
        guard ocrPastedImages else { attachForVLM(image); return }
        withAnimation(.easeInOut(duration: 0.15)) { isRecognizingText = true }
        Task { @MainActor in
            defer { withAnimation(.easeInOut(duration: 0.15)) { isRecognizingText = false } }
            if let result = await VisionTextService.recognizeText(in: image),
               VisionTextService.isTextDense(result) {
                let extracted = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.inputText += viewModel.inputText.isEmpty ? extracted : "\n\n" + extracted
                inputController.focus()
            } else {
                attachForVLM(image)
            }
        }
    }

    /// Attach the image for the vision model (the pre-OCR behavior): a thumbnail now, and an
    /// `[Image: path]` marker on send, which the sidecar routes to `describe_image`.
    private func attachForVLM(_ image: NSImage) {
        pendingImage = image
        pendingAttachment = saveAttachment(image)
    }

    /// The attach-image button — an NSOpenPanel file picker. The reliable, discoverable way to
    /// add an image (paste and drag-drop are the shortcuts); routes through the same paste path.
    private func presentImagePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.message = "Choose an image to attach"
        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) {
            handleImagePaste(image)
        }
    }

    /// SwiftUI drop handler for the input bar. An NSTextView under SwiftUI hosting never receives
    /// drag events, so drops are handled here (not in the text view) and routed through the same
    /// paste path (OCR fast-path / VLM attach).
    private func loadDroppedImage(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // Image file dragged from Finder → a file URL we load into an NSImage.
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, let image = NSImage(contentsOf: url) {
                    Task { @MainActor in handleImagePaste(image) }
                }
            }
            return true
        }
        // Raw image content (e.g. dragged from a browser) → image data. (NSImage doesn't conform
        // to NSItemProviderReading on macOS, so we load Data and build the image ourselves.)
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            if let data, let image = NSImage(data: data) {
                Task { @MainActor in handleImagePaste(image) }
            }
        }
        return true
    }

    private func saveAttachment(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LGAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".png")
        try? png.write(to: url)
        return url
    }

    // Empty stored value = unconfigured → nil → sidecar enables all tools.
    private func decodedEnabledTools() -> [String]? {
        guard !enabledToolsJSON.isEmpty,
              let data = enabledToolsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return list
    }

    private func decodedMcpHintsEnabled() -> [String: Bool]? {
        guard let data = mcpHintsEnabledJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data),
              dict.values.contains(true)
        else { return nil }
        return dict
    }

    // MARK: Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            let projectDir = activeProjectDir   // resolve once per render, not per bubble
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 50)
                    // NOT LazyVStack. Every hard freeze we've sampled — the GFM-table
                    // hang and the read-aloud hang — wedged inside
                    // LazyLayoutViewCache.updateItemPhases(), which posts a graph
                    // mutation that re-dirties the graph and never converges with
                    // variable-height bubbles under .defaultScrollAnchor(.bottom).
                    // Conversations here top out around 50 messages, so eager layout
                    // is cheap. Do not "optimise" this back to lazy.
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(viewModel.messages) { msg in
                            if msg.role == .system {
                                SystemNoticeRow(text: msg.content)
                                    .id(msg.id)
                            } else {
                                // Offer "Consult the big model" only on the latest local
                                // answer (not streaming, not already a cloud turn).
                                let canConsult = msg.id == viewModel.messages.last?.id
                                    && msg.role == .assistant
                                    && !msg.isStreaming
                                    && !(msg.model?.contains("cloud") ?? false)
                                MessageBubble(message: msg, projectDir: projectDir,
                                              onConsult: canConsult ? { consult() } : nil)
                                    .equatable()
                                    .id(msg.id)
                            }
                        }
                        // "View Report" row — appears below last message after research completes
                        if let reportPath = viewModel.researchReportPath, !viewModel.isResearching {
                            researchCompleteRow(path: reportPath)
                                .id("research-complete")
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                        Color.clear.frame(height: inputReserve + 8).id("bottom")
                    }
                    .frame(maxWidth: 960)
                    .padding(.horizontal, 24)
                    .padding(.top, 96)
                    Spacer(minLength: 50)
                }
            }
            .defaultScrollAnchor(.bottom)
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 80)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 120)
                }
            )
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: viewModel.researchReportPath) { _, path in
                if path != nil {
                    withAnimation { proxy.scrollTo("research-complete", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func researchCompleteRow(path: String) -> some View {
        HStack {
            Spacer(minLength: 50)
            Button {
                if let path = viewModel.researchReportPath {
                    withAnimation(.easeInOut(duration: 0.28)) { reportPanel.show(path) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 12))
                    Text("View Report")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Floating input bar

    private var floatingInputBar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                // Errors only. The running transcript moved into the formatting
                // row, so keeping this strip for it would say the same thing
                // twice and stack a fourth band above the composer. A denied mic
                // or failed asset install still needs to be readable, and it
                // clears on the next mic press.
                if speechInput.errorMessage != nil {
                    ListeningStrip()
                        .transition(.opacity)
                }
                if !uncertainWords.isEmpty {
                    reviewStrip
                        .transition(.opacity)
                }
                if isRecognizingText {
                    ocrReadingStrip
                        .transition(.opacity)
                }
                if let img = pendingImage {
                    attachmentStrip(img)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                // Text field — top of the bar. In voice mode the spectrograph
                // takes its place, EXCEPT when a transcript is waiting to be
                // corrected: when the system needs help it shows words, not a
                // waveform. Fixing and sending returns the spectrograph.
                if composerMode.isVoice && uncertainWords.isEmpty {
                    SpectrographView(
                        levels: speechInput.levels,
                        tint: ComposerTint.voice,
                        state: spectrographState
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .transition(.opacity)
                } else {
                    inputTextField
                }
                // Bottom row: formatting buttons (when focused) + send/stop button
                inputBottomBar
            }
            .frame(maxWidth: 960)
            .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
            // Mode wash. Over the glass rather than under it, so the tint is
            // actually visible instead of being averaged away by the material.
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ComposerTint.color(for: composerMode))
                    .opacity(ComposerTint.opacity(for: composerMode, scheme: colorScheme))
                    .allowsHitTesting(false)
            )
            .animation(.easeInOut(duration: 0.28), value: composerMode)
            .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                loadDroppedImage(providers)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 2 : 0)
                    .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
            )
            // "Working" shimmer — a light lap around the border for as long as the turn
            // runs. Persists through tool calls, where the thinking label has already
            // been replaced by tool cards and only STOP hinted that work continues.
            .overlay {
                if viewModel.isStreaming {
                    ProcessingShimmerBorder(
                        cornerRadius: 16,
                        tint: composerMode.isVoice ? ComposerTint.voice : .accentColor
                    )
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 30)
        .animation(.easeInOut(duration: 0.16), value: inputFocused)
        .animation(.easeInOut(duration: 0.3), value: viewModel.isStreaming)
    }

    private var inputTextField: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.inputText.isEmpty {
                Text(inputPlaceholder)
                    .font(fontChoice.font(fontSize))
                    .tracking(ChatFont.tracking(fontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .padding(.top, 7)
                    .allowsHitTesting(false)
            }
            ChatInputEditor(
                text: $viewModel.inputText,
                height: $inputHeight,
                fontSize: fontSize,
                lineHeight: lineHeight,
                fontChoice: fontChoice,
                minHeight: inputMinHeight,
                maxHeight: inputMaxHeight,
                controller: inputController,
                isEditable: !viewModel.isStreaming,
                onSend: { submit() },
                onImagePaste: { handleImagePaste($0) },
                onFocusChange: { focused in inputFocused = focused }
            )
            .frame(height: inputHeight)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .opacity(viewModel.isStreaming ? lockedOpacity : 1)
    }

    private var inputPlaceholder: String {
        if viewModel.isStreaming { return "Alice is working…" }
        return viewModel.researchMode
            ? "What should I research?   (Enter to send · Shift+Enter for newline)"
            : "Message Alice…   (Enter to send · Shift+Enter for newline)"
    }

    /// Compact label for the switcher: name + variant so it's clear WHICH model is
    /// selected ("gemma4:26b", "gpt-oss:120b-cloud"). Any `namespace/` prefix is
    /// dropped, and a bare `latest` tag (which carries no info) collapses to just the
    /// name — so "s80982708/ZINI-LOCAL:latest" reads "ZINI-LOCAL", not "latest".
    private var modelSwitcherLabel: String {
        guard let m = effectiveModel else { return "Auto" }
        let bare = m.split(separator: "/").last.map(String.init) ?? m   // drop namespace/
        let parts = bare.split(separator: ":", maxSplits: 1).map(String.init)
        let base = parts.first ?? bare
        let tag = parts.count > 1 ? parts[1] : ""
        return (tag.isEmpty || tag == "latest") ? base : "\(base):\(tag)"
    }

    private var modelSwitcher: some View {
        Menu {
            // Clear → follow the global default. Shows what that currently resolves to.
            let g = selectedModel.isEmpty ? "Auto" : selectedModel
            Button { selectChatModel(nil) } label: {
                if chatModelOverride == nil {
                    Label("Global default (\(g))", systemImage: "checkmark")
                } else {
                    Text("Global default (\(g))")
                }
            }
            if !catalog.models.isEmpty {
                Divider()
                ForEach(catalog.models) { model in
                    let title = model.name
                        + (model.recommended ? " ★" : "")
                        + (model.isCloud ? " ☁" : "")
                    Button { selectChatModel(model.name) } label: {
                        if chatModelOverride == model.name {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chatModelOverride != nil ? "cpu.fill" : "cpu")
                    .font(.system(size: 11))
                Text(modelSwitcherLabel)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(chatModelOverride != nil ? Color.accentColor : Color.secondary.opacity(0.8))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(chatModelOverride != nil ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(viewModel.isStreaming)
        .help("Model for this chat. Overrides the global default here only.")
    }

    private var inputBottomBar: some View {
        HStack(alignment: .center, spacing: 2) {
            // Attach image — file picker. The reliable, discoverable input path (paste + drag are
            // shortcuts). Always visible.
            Button { presentImagePicker() } label: {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isStreaming)
            .opacity(viewModel.isStreaming ? lockedOpacity : 1)
            .help("Attach an image")
            // Formatting buttons are dead weight in voice mode, so the row is
            // reused for the running transcript rather than adding yet another
            // strip above the composer. One dim line: enough to catch a
            // disaster mid-sentence, not enough to become a second text field.
            if composerMode.isVoice {
                Group {
                    if viewModel.isStreaming {
                        // The mic is muted here, so "Listening…" would be a lie.
                        // Alice's own thinking words belong in the composer once
                        // it's the thing that's working.
                        ThinkingLabel(font: .system(size: 11), tracking: 0)
                    } else {
                        Text(voiceTranscriptLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .padding(.leading, 6)
            } else if inputFocused {
                Group {
                    FormatButton(icon: "bold", help: "Bold") { inputController.wrap(prefix: "**", suffix: "**") }
                    FormatButton(icon: "italic", help: "Italic") { inputController.wrap(prefix: "*", suffix: "*") }
                    FormatButton(icon: "chevron.left.forwardslash.chevron.right", help: "Inline code") { inputController.wrap(prefix: "`", suffix: "`") }
                    FormatButton(icon: "curlybraces", help: "Code block") { inputController.wrap(prefix: "\n```\n", suffix: "\n```\n") }
                    FormatButton(icon: "list.bullet", help: "List item") { inputController.wrap(prefix: "\n- ", suffix: "") }
                }
                .disabled(viewModel.isStreaming)
                .opacity(viewModel.isStreaming ? lockedOpacity : 1)
            }
            Spacer()
            // Per-chat model switcher — quick-access; sets this chat's override (not the
            // global default). The Cheshire "Model" side panel sets the global default.
            modelSwitcher
                .opacity(viewModel.isStreaming ? lockedOpacity : 1)
                .padding(.trailing, 2)
            // Deep Research toggle — right of formatting buttons, left of send
            Button {
                viewModel.researchMode.toggle()
                inputController.focus()
            } label: {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 15, weight: viewModel.researchMode ? .semibold : .regular))
                    .foregroundStyle(viewModel.researchMode ? Color.accentColor : Color.secondary.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(viewModel.researchMode ? Color.accentColor.opacity(0.1) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isStreaming)
            .opacity(viewModel.isStreaming ? lockedOpacity : 1)
            .help(viewModel.researchMode
                  ? "Deep Research active — Alice will search, read sources, and synthesize a report"
                  : "Enable Deep Research mode")
            .padding(.trailing, 4)

            // Dictation auto-sends — unless the recogniser flagged a word it
            // doubted, in which case it lands in the composer instead and waits.
            // The system asks for help only when it knows it needs it.
            MicButton(
                isDisabled: viewModel.isStreaming,
                isVoiceMode: voiceModeArmed,
                onToggleVoiceMode: { toggleVoiceMode() }
            ) { utterance in
                // A bare mic-hold is a one-off dictation, so it never narrates;
                // arming voice mode is what asks Alice to speak back.
                deliver(utterance, narrate: voiceModeArmed)
            }
            .padding(.trailing, 4)

            Button {
                if viewModel.isStreaming {
                    viewModel.cancelStream()
                } else if speechOutput.isActive {
                    // While Alice narrates, send *is* stop — she's the only
                    // thing in flight, and the mic un-mutes the moment she ends.
                    speechOutput.stop()
                } else if composerMode.isVoice {
                    sendFromVoice()
                } else {
                    submit()
                }
            } label: {
                Image(systemName: sendButtonIsStop ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(sendButtonIsStop ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            // In voice mode the composer is empty by definition — what would be
            // sent lives in the transcript, so the text-emptiness test doesn't
            // apply.
            .disabled(!sendButtonIsStop && !composerMode.isVoice
                      && viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && pendingAttachment == nil)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.16), value: inputFocused)
    }

    /// Shown instead of auto-sending when the recogniser doubted a word. Naming
    /// the words matters twice over: it tells Yogi where to look, and it makes a
    /// badly tuned confidence floor obvious the moment it fires on the wrong things.
    private var reviewStrip: some View {
        HStack(spacing: 7) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text("Not sure about \(uncertainWords.joined(separator: ", ")) — edit if needed, then send.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                dictationUnderReview = nil
                uncertainWords = []
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sendButtonIsStop: Bool { viewModel.isStreaming || speechOutput.isActive }

    /// Alice has the floor: thinking or talking. The mic is deaf for all of it.
    ///
    /// Muting only while she *spoke* was too narrow — between send and her first
    /// token the mic stayed live, so the display kept reacting to room noise
    /// while nothing was being listened to. Reacting to sound nobody is
    /// listening to is worse than showing nothing.
    private var aliceHasTheFloor: Bool { viewModel.isStreaming || speechOutput.isActive }

    private var spectrographState: SpectrographState {
        if viewModel.isStreaming { return .processing }
        if speechOutput.isActive { return .speaking }
        return speechInput.isListening ? .live : .armed
    }

    private func toggleVoiceMode() {
        voiceModeArmed.toggle()
        // Leaving the mode must close the mic, whatever opened it.
        if !voiceModeArmed, speechInput.state != .idle {
            Task { await speechInput.cancel() }
        }
    }

    /// Send without leaving voice mode: snapshot what's been heard, keep the
    /// session alive, and let the next utterance start straight away.
    private func sendFromVoice() {
        Task {
            let utterance = await speechInput.commit()
            deliver(utterance, narrate: composerMode.narratesReplies)
        }
    }

    /// The single path a finished utterance takes, whether it came from the mic
    /// switching off or from send-in-voice-mode.
    private func deliver(_ utterance: SpeechInputService.Utterance, narrate: Bool) {
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let typed = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.inputText = typed.isEmpty ? text : typed + " " + text

        if utterance.needsReview {
            // Hand it over for correction instead of sending. The spectrograph
            // yields to the text field for as long as this is pending.
            dictationUnderReview = text
            uncertainWords = utterance.uncertain
            inputController.focus()
            return
        }
        narrateNextReply = narrate
        submit(source: .dictated)
    }

    /// Truncated from the head, so the tail — the words just spoken — stays put
    /// instead of the line scrolling away from under the eye.
    private var voiceTranscriptLine: String {
        if speechOutput.isActive { return "Alice is speaking…" }
        // Named explicitly, and said to be one-off: a multi-minute wait the
        // first time you ever press the mic needs to explain itself, or it
        // reads as the feature being broken.
        if let fraction = speechInput.downloadProgress {
            return "Downloading the speech model — \(Int(fraction * 100))%. One time only."
        }
        if speechInput.state == .preparing { return "Getting ready…" }
        let text = speechInput.transcript
        if !text.isEmpty { return text }
        // Armed but closed. The shortcut is invisible otherwise, and a mic that
        // deliberately isn't listening needs to say so or it reads as broken.
        if !speechInput.isListening {
            return "Hold SPACE to talk · double-tap SPACE to stay on"
        }
        return "Listening…"
    }

    /// Brief inline indicator while a pasted image is being OCR'd (usually well under a second).
    private var ocrReadingStrip: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text("Reading text…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attachmentStrip(_ image: NSImage) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            Text("Image attached")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    pendingAttachment = nil
                    pendingImage = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

}

/// Centered, low-key inline banner for `.system` notices (e.g. model-no-longer-installed).
/// Not a chat bubble — no avatar, no actions.
struct SystemNoticeRow: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Color.primary.opacity(0.06))
                )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

struct FormatButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 26, height: 24)
                .background(hovering ? Color.primary.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
