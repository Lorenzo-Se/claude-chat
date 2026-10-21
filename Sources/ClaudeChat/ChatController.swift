import AppKit
import ClaudeChatCore
import Observation

/// Owns conversations and requests. Every request is bound to its conversation ID, so switching
/// conversations while a response streams never mixes them up; each conversation runs at most one request.
@MainActor
@Observable
final class ChatController {
    private(set) var index: [ConversationIndexEntry] = []
    private(set) var activeID: UUID
    private(set) var runningIDs: Set<UUID> = []
    private(set) var streamingMessageIDs: [UUID: UUID] = [:]
    private(set) var saveError: String?

    var input = ""
    var pendingAttachments: [String] = []

    /// Wired by the app delegate.
    @ObservationIgnored var showPanel: () -> Void = {}
    @ObservationIgnored var focusInput: () -> Void = {}

    @ObservationIgnored private var conversations: [UUID: Conversation] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// A request of a deleted conversation may still finish; its late updates must not re-create it.
    @ObservationIgnored private var deletedIDs: Set<UUID> = []
    @ObservationIgnored private let repository: ConversationRepository
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let speech: SpeechService
    @ObservationIgnored let resolver = CLIResolver()

    /// Bumped on every visible change of a loaded conversation so views re-read it.
    private var revision = 0

    init(repository: ConversationRepository, settings: AppSettings, speech: SpeechService) {
        self.repository = repository
        self.settings = settings
        self.speech = speech
        let loaded = repository.loadIndex()
        index = loaded
        activeID = loaded.first?.id ?? UUID()
        if index.isEmpty { createConversation() }
    }

    // MARK: - Reading

    var active: Conversation {
        _ = revision
        return conversation(activeID)
    }

    var anyRunning: Bool { !runningIDs.isEmpty }

    func isRunning(_ id: UUID) -> Bool { runningIDs.contains(id) }

    private func conversation(_ id: UUID) -> Conversation {
        if let loaded = conversations[id] { return loaded }
        let loaded = repository.load(id: id) ?? Conversation(id: id)
        conversations[id] = loaded
        return loaded
    }

    private func update(_ id: UUID, _ change: (inout Conversation) -> Void) {
        guard !deletedIDs.contains(id) else { return }
        var conversation = conversation(id)
        change(&conversation)
        conversations[id] = conversation
        revision &+= 1
    }

    // MARK: - Conversation management

    func select(_ id: UUID) {
        guard id != activeID, index.contains(where: { $0.id == id }) else { return }
        activeID = id
        focusInput()
    }

    func newConversation() {
        // An untouched conversation is reused instead of piling up empty ones.
        if !(active.messages.isEmpty && !isRunning(activeID)) {
            createConversation()
        }
        pendingAttachments = []
        focusInput()
    }

    private func createConversation() {
        let conversation = Conversation()
        conversations[conversation.id] = conversation
        persist(conversation)
        activeID = conversation.id
    }

    func delete(_ id: UUID) {
        deletedIDs.insert(id)
        tasks[id]?.cancel()
        do {
            index = try repository.delete(id: id, index: index)
            saveError = nil
        } catch {
            deletedIDs.remove(id)
            saveError = "Could not delete conversation: \(error.localizedDescription)"
            return
        }
        conversations[id] = nil
        if activeID == id {
            if let next = index.first {
                activeID = next.id
            } else {
                createConversation()
            }
        }
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = String(trimmed.prefix(80)) }
        persist(conversation(id))
    }

    // MARK: - Sending

    var canSend: Bool {
        !isRunning(activeID)
            && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
    }

    func sendInput() {
        guard canSend else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        input = ""
        pendingAttachments = []
        let display = text.isEmpty ? attachments.map(Self.fileName).joined(separator: ", ") : text
        start(
            in: activeID,
            prompt: ClaudeCommand.prompt(text: text, attachments: attachments),
            display: display,
            attachments: attachments,
            feature: nil
        )
    }

    func stop(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func stopAll() {
        tasks.values.forEach { $0.cancel() }
    }

    func removePendingAttachment(_ path: String) {
        pendingAttachments.removeAll { $0 == path }
    }

    // MARK: - Features (hotkeys)

    func handleScreenshot(path: String) {
        let feature = settings.screenshot
        guard feature.useSystemPrompt else {
            pendingAttachments.append(path)
            showPanel()
            return
        }
        start(
            in: idleConversationID(),
            prompt: ClaudeCommand.prompt(text: PromptTemplates.screenshot(feature.systemPrompt, path: path), attachments: [path]),
            display: Self.fileName(path),
            attachments: [path],
            feature: .screenshot
        )
    }

    func handleWebsite(_ content: WebsiteContent) {
        let feature = settings.website
        guard feature.useSystemPrompt else {
            input = PromptTemplates.rawWebsite(content)
            update(activeID) { $0.setTitleIfDefault(from: content.title.isEmpty ? "Website" : content.title) }
            persist(conversation(activeID))
            showPanel()
            return
        }
        let template = PromptTemplates.websiteTemplate(
            for: content,
            defaultPrompt: feature.systemPrompt,
            overrides: settings.websiteURLPromptOverrides
        )
        let target = idleConversationID()
        update(target) { $0.setTitleIfDefault(from: content.title.isEmpty ? "Website" : content.title) }
        start(
            in: target,
            prompt: PromptTemplates.website(template, content: content),
            display: PromptTemplates.websiteSummary(content),
            attachments: [],
            feature: .website
        )
    }

    func handleFiles(paths: [String]) throws {
        let imported = try paths.map(Self.importAttachment)
        let feature = settings.file
        guard feature.useSystemPrompt else {
            pendingAttachments.append(contentsOf: imported)
            showPanel()
            return
        }
        let text = PromptTemplates.files(feature.systemPrompt, paths: imported)
        start(
            in: idleConversationID(),
            prompt: ClaudeCommand.prompt(text: text, attachments: imported),
            display: imported.map(Self.fileName).joined(separator: ", "),
            attachments: imported,
            feature: .file
        )
    }

    /// Regular files are snapshotted into the cache; folders are passed as-is (they can be huge).
    private static func importAttachment(_ path: String) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ChatError("File not found: \(path)")
        }
        if isDirectory.boolValue { return path }
        do {
            return try AppPaths.attachments.importCopy(of: path)
        } catch {
            throw ChatError("Could not attach \(fileName(path)): \(error.localizedDescription)")
        }
    }

    /// Feature prompts go to the active conversation unless it is busy; then a new one is started.
    private func idleConversationID() -> UUID {
        if isRunning(activeID) { createConversation() }
        return activeID
    }

    // MARK: - Request lifecycle

    private func start(in id: UUID, prompt: String, display: String, attachments: [String], feature: FeatureSource?) {
        guard !isRunning(id) else { return }

        let assistant = Message(role: .assistant, content: "")
        update(id) {
            $0.messages.append(Message(role: .user, content: display, attachments: attachments))
            $0.setTitleIfDefault(from: display)
        }
        persist(conversation(id))
        update(id) { $0.messages.append(assistant) }

        runningIDs.insert(id)
        streamingMessageIDs[id] = assistant.id
        focusInput()

        tasks[id] = Task { [weak self] in
            await self?.run(conversationID: id, assistantID: assistant.id, prompt: prompt, feature: feature)
        }
    }

    private func run(conversationID id: UUID, assistantID: UUID, prompt: String, feature: FeatureSource?) async {
        defer {
            tasks[id] = nil
            runningIDs.remove(id)
            streamingMessageIDs[id] = nil
        }

        let streamer = StreamingText { [weak self] text in
            self?.setContent(text, of: assistantID, in: id)
        }
        var accumulator = ResponseAccumulator()
        do {
            let environment = try await resolver.resolve(override: settings.cliPathOverride)
            var sessionId = conversation(id).claudeSessionId
            do {
                accumulator = try await stream(prompt, sessionId: sessionId, environment: environment, streamer: streamer)
            } catch ClaudeRunError.missingSession where sessionId != nil {
                sessionId = nil
                update(id) {
                    $0.claudeSessionId = nil
                    $0.messages.insert(
                        Message(role: .system, content: "The previous Claude session no longer exists — continuing in a new session without earlier context."),
                        at: max(0, $0.messages.count - 1)
                    )
                }
                accumulator = try await stream(prompt, sessionId: nil, environment: environment, streamer: streamer)
            }

            let finalText = accumulator.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            setContent(finalText.isEmpty ? "_(No text response)_" : finalText, of: assistantID, in: id)
            update(id) { $0.claudeSessionId = accumulator.sessionId ?? $0.claudeSessionId }
            persist(conversation(id))

            if let feature, !finalText.isEmpty {
                applyPostSendActions(settings.feature(feature), response: finalText, messageID: assistantID)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            update(id) { conversation in
                if let index = conversation.messages.firstIndex(where: { $0.id == assistantID }),
                   conversation.messages[index].content.isEmpty {
                    conversation.messages.remove(at: index)
                }
                conversation.messages.append(Message(role: .system, content: message))
                if let sessionId = streamer.sessionId { conversation.claudeSessionId = sessionId }
            }
            persist(conversation(id))
            // Background feature requests would otherwise fail silently.
            if feature != nil, (error as? ClaudeRunError) != .cancelled {
                showPanel()
            }
        }
    }

    private func stream(_ prompt: String, sessionId: String?, environment: CLIEnvironment, streamer: StreamingText) async throws -> ResponseAccumulator {
        var accumulator = ResponseAccumulator()
        let command = ClaudeCommand(prompt: prompt, sessionId: sessionId, model: settings.model.cliValue)
        let showLive = settings.streamingEnabled
        for try await event in ClaudeRunner.run(command, environment: environment) {
            let changed = accumulator.apply(event)
            streamer.sessionId = accumulator.sessionId
            if changed, showLive { streamer.submit(accumulator.text) }
        }
        // A cancelled consumer ends the stream normally; the partial answer must not count as success.
        if Task.isCancelled { throw ClaudeRunError.cancelled }
        streamer.flush()
        return accumulator
    }

    private func setContent(_ text: String, of messageID: UUID, in id: UUID) {
        update(id) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conversation.messages[index].content = text
        }
    }

    private func applyPostSendActions(_ feature: FeatureSettings, response: String, messageID: UUID) {
        if feature.openChatAfterSend { showPanel() }
        if feature.copyToClipboardAfterSend {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(response, forType: .string)
        }
        if feature.speakAfterSend {
            speech.speak(markdown: response, id: messageID)
        }
    }

    // MARK: - Persistence

    private func persist(_ conversation: Conversation) {
        guard !deletedIDs.contains(conversation.id) else { return }
        var stamped = conversation
        stamped.updatedAt = Date()
        // Never persist the empty placeholder of a response that is still streaming.
        stamped.messages.removeAll { $0.role == .assistant && $0.content.isEmpty }
        conversations[stamped.id]?.updatedAt = stamped.updatedAt
        do {
            index = try repository.save(stamped, index: index)
            saveError = nil
        } catch {
            saveError = "Could not save conversation: \(error.localizedDescription)"
        }
    }

    /// On quit: stop requests and keep whatever was streamed so far.
    func prepareForTermination() {
        for id in runningIDs {
            tasks[id]?.cancel()
            persist(conversation(id))
        }
    }

    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

struct ChatError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Coalesces streamed text into at most ~20 UI updates per second.
@MainActor
private final class StreamingText {
    var sessionId: String?
    private let apply: (String) -> Void
    private var latest: String?
    private var scheduled = false

    init(apply: @escaping (String) -> Void) {
        self.apply = apply
    }

    func submit(_ text: String) {
        latest = text
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.flush()
        }
    }

    func flush() {
        scheduled = false
        if let latest {
            apply(latest)
            self.latest = nil
        }
    }
}
