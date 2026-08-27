import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotStoreError: LocalizedError {
    case directoryCreationFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed:
            return "Screenshot directory could not be created."
        case .pngEncodingFailed:
            return "Screenshot could not be saved as PNG."
        }
    }
}

final class ScreenshotStore {
    static let shared = ScreenshotStore()

    private let fileManager = FileManager.default
    private let directory: URL
    private let maxAge: TimeInterval = 24 * 60 * 60

    init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.claudechat"
        directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func cleanupOldScreenshots() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)

        for file in files where file.pathExtension.lowercased() == "png" {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate else { continue }
            if modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    func savePNG(_ image: CGImage) throws -> String {
        if !fileManager.fileExists(atPath: directory.path) {
            guard (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
                throw ScreenshotStoreError.directoryCreationFailed
            }
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(timestamp)_\(UUID().uuidString).png"
        let url = directory.appendingPathComponent(filename)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotStoreError.pngEncodingFailed
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotStoreError.pngEncodingFailed
        }

        return url.path
    }
}
