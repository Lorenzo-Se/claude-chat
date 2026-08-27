import Foundation

struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var claudeSessionId: String?
    var messages: [Message]

    init(
        id: UUID = UUID(),
        title: String = "New Conversation",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        claudeSessionId: String? = nil,
        messages: [Message] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.claudeSessionId = claudeSessionId
        self.messages = messages
    }
}

struct ConversationIndexEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var updatedAt: Date
}

struct ConversationIndex: Codable {
    var conversations: [ConversationIndexEntry]

    init(conversations: [ConversationIndexEntry] = []) {
        self.conversations = conversations
    }
}
