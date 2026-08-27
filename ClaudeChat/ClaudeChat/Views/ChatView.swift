import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var conversation: Conversation
    @Published var inputText = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

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

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        inputText = ""
        errorMessage = nil

        let userMessage = Message(role: .user, content: text)
        conversation.messages.append(userMessage)

        if conversation.title == "Neue Konversation" {
            conversation.title = String(text.prefix(40))
        }

        try? store.save(conversation)

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await processManager.send(
                prompt: text,
                conversationId: conversation.id,
                sessionId: conversation.claudeSessionId
            )

            if let sessionId = response.session_id {
                conversation.claudeSessionId = sessionId
            }

            let assistantText = response.result ?? ""
            conversation.messages.append(Message(role: .assistant, content: assistantText))
            try store.save(conversation)
        } catch {
            let errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            conversation.messages.append(Message(role: .system, content: errorText))
            try? store.save(conversation)
            errorMessage = errorText
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
        errorMessage = nil
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
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }

                    if viewModel.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Claude denkt nach …")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 12)
                        .id("loading")
                    }
                }
                .padding(16)
            }
            .onChange(of: viewModel.conversation.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.isLoading) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private var inputArea: some View {
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
                .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if viewModel.isLoading {
            withAnimation { proxy.scrollTo("loading", anchor: .bottom) }
        } else if let last = viewModel.conversation.messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}
