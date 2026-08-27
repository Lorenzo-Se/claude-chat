import Foundation

enum AttachmentStoreError: LocalizedError {
    case directoryCreationFailed
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed:
            return "Anhang-Verzeichnis konnte nicht erstellt werden."
        case .copyFailed(let path):
            return "Datei konnte nicht angehängt werden: \(path)"
        }
    }
}

final class AttachmentStore {
    static let shared = AttachmentStore()

    private let fileManager = FileManager.default
    private let directory: URL
    private let maxAge: TimeInterval = 24 * 60 * 60

    init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.claudechat"
        directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func cleanupOldAttachments() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)

        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate else { continue }
            if modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// Kopiert eine Datei in den App-Cache und gibt den neuen Pfad zurück.
    func importFile(from sourcePath: String) throws -> String {
        try ensureDirectory()

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let originalName = sourceURL.lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(timestamp)_\(UUID().uuidString)_\(originalName)"
        let destination = directory.appendingPathComponent(filename)

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination.path
        } catch {
            throw AttachmentStoreError.copyFailed(sourcePath)
        }
    }

    private func ensureDirectory() throws {
        if !fileManager.fileExists(atPath: directory.path) {
            guard (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
                throw AttachmentStoreError.directoryCreationFailed
            }
        }
    }
}
