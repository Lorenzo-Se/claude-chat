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

    init(conversation: Conversation, store: ConversationStore, processManager: ClaudeProcessManager) {
        self.conversation = conversation
        self.store = store
        self.processManager = processManager
    }

    func reloadFromStore() {
        if let loaded = store.loadConversation(id: conversation.id) {
            conversation = loaded
        }
    }

    func attachScreenshot(path: String) {
        pendingAttachmentPath = path
        errorMessage = nil
    }

    func removePendingAttachment() {
        pendingAttachmentPath = nil
    }

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = pendingAttachmentPath
        guard !text.isEmpty || attachment != nil, !isLoading else { return }

        inputText = ""
        pendingAttachmentPath = nil
        errorMessage = nil

        let displayContent = text.isEmpty ? "Screenshot" : text
        let userMessage = Message(
            role: .user,
            content: displayContent,
            attachmentPath: attachment
        )
        conversation.messages.append(userMessage)

        if conversation.title == "Neue Konversation" {
            let titleSource = text.isEmpty ? "Screenshot" : text
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
                prompt: text,
                conversationId: conversation.id,
                sessionId: conversation.claudeSessionId,
                attachmentPath: attachment
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

    func sendScreenshot(path: String, prompt: String = "") async {
        attachScreenshot(path: path)
        inputText = prompt
        await sendMessage()
    }

    func sendWebsiteContent(prompt: String, pageTitle: String) async {
        inputText = prompt
        errorMessage = nil

        if conversation.title == "Neue Konversation" {
            let titleSource = pageTitle.isEmpty ? "Website" : pageTitle
            conversation.title = String(titleSource.prefix(40))
            try? store.save(conversation)
        }

        await sendMessage()
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
        errorMessage = nil
        streamingMessageId = nil
    }
}

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var store: ConversationStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            inputArea
        }
        .frame(minWidth: 360, minHeight: 480)
        .onChange(of: store.activeConversationId) { _, newId in
            if let newId, let loaded = store.loadConversation(id: newId) {
                viewModel.conversation = loaded
            }
        }
    }

    private var header: some View {
        HStack {
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
                TextField("Nachricht …", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit {
                        Task { await viewModel.sendMessage() }
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
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }

            Text("Screenshot angehängt")
                .font(.caption)
                .foregroundStyle(.secondary)

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
