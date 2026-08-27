import AppKit
import Foundation

enum FileContextServiceError: LocalizedError {
    case keineDateiGefunden
    case automationDenied
    case invalidPath(String)
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .keineDateiGefunden:
            return "Keine Datei gefunden. Öffne eine Datei in der Vorschau oder markiere Dateien im Finder."
        case .automationDenied:
            return "Automation-Berechtigung fehlt. Erlaube Claude Chat in Systemeinstellungen → Datenschutz & Sicherheit → Automation die Steuerung von Vorschau und Finder."
        case .invalidPath(let path):
            return "Ungültiger oder nicht erreichbarer Pfad: \(path)"
        case .appleScriptFailed(let detail):
            return "AppleScript-Fehler: \(detail)"
        }
    }
}

enum FileContextService {
    private static let previewBundleID = "com.apple.Preview"

    private static let previewScript = """
    tell application "Preview"
        if (count of documents) = 0 then return ""
        try
            return path of front document
        on error
            try
                return path of document of front window
            on error
                return ""
            end try
        end try
    end tell
    """

    private static let finderScript = """
    tell application "Finder"
        set sel to selection
        if sel is {} then return ""
        set paths to ""
        repeat with f in sel
            set paths to paths & POSIX path of (f as alias) & linefeed
        end repeat
        return paths
    end tell
    """

    static func resolveActiveFilePaths() async throws -> [String] {
        let permissionsOK = await AutomationPermissionManager.ensurePermissions()
        guard permissionsOK else {
            throw FileContextServiceError.automationDenied
        }

        if isFrontmostApp(bundleID: previewBundleID) {
            if let path = try await previewDocumentPath(), !path.isEmpty {
                try validatePaths([path])
                return [path]
            }
        }

        let finderPaths = try await finderSelectionPaths()
        if !finderPaths.isEmpty {
            try validatePaths(finderPaths)
            return finderPaths
        }

        if let path = try await previewDocumentPath(), !path.isEmpty {
            try validatePaths([path])
            return [path]
        }

        throw FileContextServiceError.keineDateiGefunden
    }

    static func applyFileTemplate(_ template: String, paths: [String], userText: String = "") -> String {
        let pathsText = paths.joined(separator: "\n")
        let primaryPath = paths.first ?? ""
        let filename = (primaryPath as NSString).lastPathComponent

        return template
            .replacingOccurrences(of: "{paths}", with: pathsText)
            .replacingOccurrences(of: "{path}", with: primaryPath)
            .replacingOccurrences(of: "{filename}", with: filename)
            .replacingOccurrences(of: "{userText}", with: userText)
    }

    private static func isFrontmostApp(bundleID: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    private static func previewDocumentPath() async throws -> String? {
        let result = try await runAppleScript(previewScript)
        guard let result, !result.isEmpty else { return nil }
        let normalized = normalizePreviewPath(result)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizePreviewPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("file://") {
            if let url = URL(string: trimmed), url.isFileURL {
                return url.path
            }
            return trimmed
                .replacingOccurrences(of: "file://localhost", with: "")
                .replacingOccurrences(of: "file://", with: "")
        }

        return trimmed
    }

    private static func finderSelectionPaths() async throws -> [String] {
        let result = try await runAppleScript(finderScript)
        guard let result, !result.isEmpty else { return [] }

        return result
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func validatePaths(_ paths: [String]) throws {
        let fileManager = FileManager.default
        for path in paths {
            guard fileManager.fileExists(atPath: path) else {
                throw FileContextServiceError.invalidPath(path)
            }
        }
    }

    private static func runAppleScript(_ source: String) async throws -> String? {
        try await MainActor.run {
            do {
                return try AppleScriptRunner.execute(source)
            } catch let error as AppleScriptRunner.Error {
                switch error {
                case .automationDenied:
                    throw FileContextServiceError.automationDenied
                case .scriptCreationFailed:
                    throw FileContextServiceError.appleScriptFailed("Script konnte nicht erstellt werden.")
                case .failed(let message, _):
                    throw FileContextServiceError.appleScriptFailed(message)
                }
            }
        }
    }
}
