import Foundation

/// Flat-file persistence: one JSON file per conversation plus `index.json` for the sidebar.
/// The index is a cache — if it is missing or unreadable it is rebuilt from the conversation files.
public struct ConversationRepository: Sendable {
    public let directory: URL

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func loadIndex() -> [ConversationIndexEntry] {
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder.chat.decode(ConversationIndex.self, from: data) {
            let existing = index.conversations.filter { FileManager.default.fileExists(atPath: fileURL(for: $0.id).path) }
            return existing.sorted { $0.updatedAt > $1.updatedAt }
        }
        let rebuilt = rebuildIndex()
        try? writeIndex(rebuilt)
        return rebuilt
    }

    public func load(id: UUID) -> Conversation? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? JSONDecoder.chat.decode(Conversation.self, from: data)
    }

    /// Writes the conversation and returns the updated, sorted index.
    public func save(_ conversation: Conversation, index: [ConversationIndexEntry]) throws -> [ConversationIndexEntry] {
        let data = try JSONEncoder.chat.encode(conversation)
        try data.write(to: fileURL(for: conversation.id), options: .atomic)

        var updated = index.filter { $0.id != conversation.id }
        updated.append(ConversationIndexEntry(conversation))
        updated.sort { $0.updatedAt > $1.updatedAt }
        try writeIndex(updated)
        return updated
    }

    public func delete(id: UUID, index: [ConversationIndexEntry]) throws -> [ConversationIndexEntry] {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let updated = index.filter { $0.id != id }
        try writeIndex(updated)
        return updated
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func writeIndex(_ entries: [ConversationIndexEntry]) throws {
        let data = try JSONEncoder.chat.encode(ConversationIndex(conversations: entries))
        try data.write(to: indexURL, options: .atomic)
    }

    private func rebuildIndex() -> [ConversationIndexEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
            .compactMap { url -> ConversationIndexEntry? in
                guard let data = try? Data(contentsOf: url),
                      let conversation = try? JSONDecoder.chat.decode(Conversation.self, from: data) else { return nil }
                return ConversationIndexEntry(conversation)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

extension JSONEncoder {
    static let chat: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let chat: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
