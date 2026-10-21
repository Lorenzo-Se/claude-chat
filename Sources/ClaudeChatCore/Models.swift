import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct Message: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public var content: String
    public let timestamp: Date
    public var attachments: [String]

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        attachments: [String] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.attachments = attachments
    }
}

extension Message: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, attachmentPath, attachmentPaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(MessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        if let paths = try container.decodeIfPresent([String].self, forKey: .attachmentPaths) {
            attachments = paths
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .attachmentPath) {
            attachments = [legacy]
        } else {
            attachments = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachmentPaths)
            // Keeps files readable by app versions that only know a single attachment.
            try container.encode(attachments[0], forKey: .attachmentPath)
        }
    }
}

public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public static let defaultTitle = "New Conversation"

    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var claudeSessionId: String?
    public var messages: [Message]

    public init(
        id: UUID = UUID(),
        title: String = Conversation.defaultTitle,
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

    /// True until the user or the first message gave the conversation a real title.
    public var hasDefaultTitle: Bool {
        title == Self.defaultTitle || title == "Neue Konversation"
    }

    public mutating func setTitleIfDefault(from source: String) {
        guard hasDefaultTitle else { return }
        let cleaned = source
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        title = String(cleaned.prefix(40))
    }
}

public struct ConversationIndexEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var updatedAt: Date

    public init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }

    public init(_ conversation: Conversation) {
        self.init(id: conversation.id, title: conversation.title, updatedAt: conversation.updatedAt)
    }
}

struct ConversationIndex: Codable {
    var conversations: [ConversationIndexEntry]
}
