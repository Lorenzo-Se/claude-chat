import AppKit
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var conversation: Conversation
    @Published var inputText = ""
    @Published var pendingAttachmentPath: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var streamingMessageId: UUID?

    private let store: ConversationStore
    private let processManager: ClaudeProcessManager
    private let settings: AppSettings

    private var pendingFeatureSource: FeatureSendSource?
    var showPanel: (() -> Void)?

    init(conversation: Conversation, store: ConversationStore, processManager: ClaudeProcessManager, settings: AppSettings = .shared) {
        self.conversation = conversation
        self.store = store
        self.processManager = processManager
        self.settings = settings
    }

    func reloadFromStore() {
        if let loaded = store.loadConversation(id: conversation.id) {
            conversation = loaded
        }
    }

    func attachFile(path: String) {
        pendingAttachmentPath = path
        errorMessage = nil
    }

    func removePendingAttachment() {
        pendingAttachmentPath = nil
    }

    func sendMessage(
        featureSource: FeatureSendSource? = nil,
        cliPrompt: String? = nil,
        displayContent: String? = nil
    ) async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = pendingAttachmentPath
        let effectivePrompt = cliPrompt ?? text
        guard !effectivePrompt.isEmpty || attachment != nil, !isLoading else { return }

        let activeFeatureSource = featureSource ?? pendingFeatureSource
        pendingFeatureSource = nil

        inputText = ""
        pendingAttachmentPath = nil
        errorMessage = nil

        let resolvedDisplay: String
        if let displayContent {
            resolvedDisplay = displayContent
        } else if text.isEmpty {
            if let attachment {
                resolvedDisplay = (attachment as NSString).lastPathComponent
            } else {
                resolvedDisplay = "Anhang"
            }
        } else {
            resolvedDisplay = text
        }

        let userMessage = Message(
            role: .user,
            content: resolvedDisplay,
            attachmentPath: attachment
        )
        conversation.messages.append(userMessage)

        if conversation.title == "Neue Konversation" {
            let titleSource = resolvedDisplay.isEmpty ? (attachment.map { ($0 as NSString).lastPathComponent } ?? "Anhang") : resolvedDisplay
            conversation.title = String(titleSource.prefix(40))
        }

        let assistantMessage = Message(role: .assistant, content: "")
        conversation.messages.append(assistantMessage)
        let assistantIndex = conversation.messages.count - 1
        streamingMessageId = assistantMessage.id

        try? store.save(conversation)

        isLoading = true
        defer {
            isLoading = false
            streamingMessageId = nil
        }

        do {
            let response = try await processManager.send(
                prompt: effectivePrompt,
                conversationId: conversation.id,
                sessionId: conversation.claudeSessionId,
                attachmentPath: attachment,
                model: settings.model.cliValue,
                streamingEnabled: settings.streamingEnabled
            ) { [weak self] delta in
                guard let self else { return }
                guard assistantIndex < self.conversation.messages.count else { return }
                var message = self.conversation.messages[assistantIndex]
                message.content += delta
                self.conversation.messages[assistantIndex] = message
            }

            if let sessionId = response.session_id {
                conversation.claudeSessionId = sessionId
            }

            if let finalText = response.result,
               assistantIndex < conversation.messages.count {
                var message = conversation.messages[assistantIndex]
                message.content = finalText
                conversation.messages[assistantIndex] = message
            }

            try store.save(conversation)

            if let activeFeatureSource {
                let finalText = response.result
                    ?? (assistantIndex < conversation.messages.count
                        ? conversation.messages[assistantIndex].content
                        : "")
                if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let actions = settings.postSendActions(for: activeFeatureSource)
                    PostSendActionHandler.apply(
                        actions: actions,
                        response: finalText,
                        showPanel: { [weak self] in
                            self?.showPanel?()
                        }
                    )
                }
            }
        } catch {
            if assistantIndex < conversation.messages.count,
               conversation.messages[assistantIndex].content.isEmpty {
                conversation.messages.remove(at: assistantIndex)
            }

            let errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            conversation.messages.append(Message(role: .system, content: errorText))
            try? store.save(conversation)
            errorMessage = errorText
        }
    }

    func sendScreenshot(path: String) async {
        attachFile(path: path)
        errorMessage = nil
        pendingFeatureSource = .screenshot

        if settings.screenshotSystemPromptEnabled {
            let cliPrompt = WebsiteContentService.applyScreenshotTemplate(
                settings.screenshotSystemPrompt,
                path: path
            )
            await sendMessage(
                featureSource: .screenshot,
                cliPrompt: cliPrompt,
                displayContent: (path as NSString).lastPathComponent
            )
        } else {
            inputText = ""
        }
    }

    func sendFiles(paths: [String]) async {
        guard !paths.isEmpty else { return }

        do {
            let cachedPaths = try paths.map { try AttachmentStore.shared.importFile(from: $0) }
            let primaryPath = cachedPaths[0]
            attachFile(path: primaryPath)
            pendingFeatureSource = .file
            errorMessage = nil

            let displayNames = cachedPaths.map { ($0 as NSString).lastPathComponent }
            let displayContent = displayNames.joined(separator: ", ")

            if settings.fileSystemPromptEnabled {
                var cliPrompt = FileContextService.applyFileTemplate(
                    settings.fileSystemPrompt,
                    paths: cachedPaths
                )
                if !cachedPaths.allSatisfy({ cliPrompt.contains($0) }) {
                    cliPrompt += "\n\nAngehängte Dateien:\n\(cachedPaths.joined(separator: "\n"))"
                }
                await sendMessage(
                    featureSource: .file,
                    cliPrompt: cliPrompt,
                    displayContent: displayContent
                )
            } else {
                inputText = displayContent
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func handleWebsiteContent(_ content: WebsiteContent) async {
        errorMessage = nil
        pendingFeatureSource = .website

        if settings.websiteSystemPromptEnabled {
            let template = WebsiteContentService.resolveSystemPrompt(
                for: content,
                defaultPrompt: settings.websiteSystemPrompt,
                overrides: settings.websiteURLPromptOverrides
            )
            inputText = WebsiteContentService.applyTemplate(template, content: content)
            prepareConversationTitle(for: content.title)
            await sendMessage(featureSource: .website)
        } else {
            inputText = WebsiteContentService.buildRawContent(for: content)
            prepareConversationTitle(for: content.title)
        }
    }

    private func prepareConversationTitle(for pageTitle: String) {
        if conversation.title == "Neue Konversation" {
            let titleSource = pageTitle.isEmpty ? "Website" : pageTitle
            conversation.title = String(titleSource.prefix(40))
            try? store.save(conversation)
        }
    }

    func stopGeneration() {
        processManager.terminate(conversationId: conversation.id)
    }

    func newConversation() throws {
        let newConv = try store.createConversation()
        store.activeConversationId = newConv.id
        conversation = newConv
        inputText = ""
        pendingAttachmentPath = nil
        pendingFeatureSource = nil
        errorMessage = nil
        streamingMessageId = nil
    }
}

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var store: ConversationStore
    @State private var showsConversationList = false
    @State private var inputHeight = ChatInputEditor.minHeight

    var body: some View {
        HStack(spacing: 0) {
            if showsConversationList {
                conversationSidebar
                Divider()
            }

            VStack(spacing: 0) {
                header
                Divider()
                messageList
                Divider()
                inputArea
            }
        }
        .frame(minWidth: showsConversationList ? 520 : 360, minHeight: 480)
        .onChange(of: store.activeConversationId) { _, newId in
            if let newId, let loaded = store.loadConversation(id: newId) {
                viewModel.conversation = loaded
            }
        }
    }

    private var conversationSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Konversationen")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            List(selection: Binding(
                get: { store.activeConversationId },
                set: { newId in
                    if let newId {
                        store.activeConversationId = newId
                    }
                }
            )) {
                ForEach(store.conversations) { entry in
                    Text(entry.title)
                        .lineLimit(1)
                        .tag(Optional(entry.id))
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 160)
    }

    private var header: some View {
        HStack {
            Button {
                showsConversationList.toggle()
            } label: {
                Image(systemName: showsConversationList ? "sidebar.left" : "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Konversationen anzeigen")

            Text(viewModel.conversation.title)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }

            Button {
                try? viewModel.newConversation()
            } label: {
                Image(systemName: "plus.message")
            }
            .buttonStyle(.borderless)
            .help("Neue Konversation")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if viewModel.conversation.messages.isEmpty {
                        Text("Stelle Claude eine Frage …")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }

                    ForEach(viewModel.conversation.messages) { message in
                        MessageBubbleView(
                            message: message,
                            isStreaming: viewModel.streamingMessageId == message.id
                        )
                        .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: viewModel.conversation.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.streamingMessageId) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.conversation.messages.last?.content) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.isLoading) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachmentPath = viewModel.pendingAttachmentPath {
                attachmentPreview(path: attachmentPath)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    ChatInputEditor(text: $viewModel.inputText, height: $inputHeight) {
                        Task { await viewModel.sendMessage() }
                    }
                    .frame(height: inputHeight)

                    if viewModel.inputText.isEmpty {
                        Text("Nachricht …")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }

                if viewModel.isLoading {
                    Button("Stop") {
                        viewModel.stopGeneration()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        Task { await viewModel.sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && viewModel.pendingAttachmentPath == nil
                    )
                }
            }
        }
        .padding(12)
    }

    private func attachmentPreview(path: String) -> some View {
        HStack(spacing: 8) {
            AttachmentChipView(path: path, maxImageHeight: 80)

            Spacer()

            Button {
                viewModel.removePendingAttachment()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Anhang entfernen")
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let streamingId = viewModel.streamingMessageId {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(streamingId, anchor: .bottom)
            }
        } else if let last = viewModel.conversation.messages.last {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct ChatInputEditor: NSViewRepresentable {
    static let minHeight: CGFloat = 24
    static let maxHeight: CGFloat = 120

    @Binding var text: String
    @Binding var height: CGFloat
    var onSend: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.height = $height
        configure(textView)
        textView.string = text

        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.updateHeight(for: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.height = $height

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }

        context.coordinator.updateHeight(for: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSend: onSend)
    }

    private func configure(_ textView: NSTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var height: Binding<CGFloat>?
        var onSend: () -> Void
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        private static let newlineSelectors: [Selector] = [
            #selector(NSTextView.insertNewline(_:)),
        ]

        init(text: Binding<String>, onSend: @escaping () -> Void) {
            _text = text
            self.onSend = onSend
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            updateHeight(for: textView)
        }

        func updateHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let width = scrollView?.contentSize.width ?? textView.bounds.width
            if width > 0 {
                textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            }

            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let inset = textView.textContainerInset
            let contentHeight = used.height + inset.height * 2
            let clamped = min(max(ceil(contentHeight), ChatInputEditor.minHeight), ChatInputEditor.maxHeight)

            scrollView?.hasVerticalScroller = contentHeight > ChatInputEditor.maxHeight
            height?.wrappedValue = clamped
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard Self.newlineSelectors.contains(commandSelector) else { return false }
            if NSEvent.modifierFlags.contains(.shift) {
                return false
            }
            onSend()
            return true
        }
    }
}
