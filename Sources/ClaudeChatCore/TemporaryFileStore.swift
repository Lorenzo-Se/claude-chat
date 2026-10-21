import Foundation

/// A cache directory for screenshots and imported attachments. Files older than `maxAge` are purged.
/// Attachments are copied here so Claude reads a stable snapshot even if the original moves.
public struct TemporaryFileStore: Sendable {
    public let directory: URL
    public let maxAge: TimeInterval

    public init(directory: URL, maxAge: TimeInterval = 24 * 60 * 60) {
        self.directory = directory
        self.maxAge = maxAge
    }

    public func purgeExpired(now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let cutoff = now.addingTimeInterval(-maxAge)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// A fresh, unique path inside the store, keeping `name` readable at the end.
    public func newFileURL(named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let short = UUID().uuidString.prefix(8)
        return directory.appendingPathComponent("\(stamp)_\(short)_\(name)")
    }

    public func importCopy(of sourcePath: String) throws -> String {
        let source = URL(fileURLWithPath: sourcePath)
        let destination = try newFileURL(named: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        // Copying also refreshes the modification date, so purging is based on import time.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        return destination.path
    }
}
