import Foundation

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [ConversationIndexEntry] = []
    @Published var activeConversationId: UUID?

    private let fileManager = FileManager.default
    private let appSupportURL: URL
    private let conversationsDirectory: URL
    private let indexURL: URL

    init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.claudechat"
        appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        conversationsDirectory = appSupportURL.appendingPathComponent("conversations", isDirectory: true)
        indexURL = conversationsDirectory.appendingPathComponent("index.json")

        try? fileManager.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)

        loadIndex()

        if conversations.isEmpty {
            let conversation = Conversation()
            try? save(conversation)
            activeConversationId = conversation.id
        } else if activeConversationId == nil {
            activeConversationId = conversations.first?.id
        }
    }

    func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder.iso8601.decode(ConversationIndex.self, from: data) else {
            conversations = []
            return
        }
        conversations = index.conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadConversation(id: UUID) -> Conversation? {
        let url = conversationURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso8601.decode(Conversation.self, from: data)
    }

    func activeConversation() -> Conversation? {
        guard let id = activeConversationId else { return nil }
        return loadConversation(id: id)
    }

    func save(_ conversation: Conversation) throws {
        var updated = conversation
        updated.updatedAt = Date()

        let data = try JSONEncoder.iso8601.encode(updated)
        try data.write(to: conversationURL(for: updated.id), options: .atomic)

        if let index = conversations.firstIndex(where: { $0.id == updated.id }) {
            conversations[index] = ConversationIndexEntry(
                id: updated.id,
                title: updated.title,
                updatedAt: updated.updatedAt
            )
        } else {
            conversations.insert(
                ConversationIndexEntry(id: updated.id, title: updated.title, updatedAt: updated.updatedAt),
                at: 0
            )
        }

        conversations.sort { $0.updatedAt > $1.updatedAt }
        try saveIndex()
    }

    func createConversation() throws -> Conversation {
        let conversation = Conversation()
        try save(conversation)
        activeConversationId = conversation.id
        return conversation
    }

    func deleteConversation(id: UUID) throws {
        try fileManager.removeItem(at: conversationURL(for: id))
        conversations.removeAll { $0.id == id }

        if activeConversationId == id {
            activeConversationId = conversations.first?.id
            if activeConversationId == nil {
                let conversation = try createConversation()
                activeConversationId = conversation.id
            }
        }

        try saveIndex()
    }

    private func conversationURL(for id: UUID) -> URL {
        conversationsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func saveIndex() throws {
        let index = ConversationIndex(conversations: conversations)
        let data = try JSONEncoder.iso8601.encode(index)
        try data.write(to: indexURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
