import AppKit

enum FileContextError: LocalizedError {
    case noFile
    case automationDenied(app: String)
    case script(String)

    var errorDescription: String? {
        switch self {
        case .noFile:
            "No file found. Select files in Finder or open a document in Preview."
        case .automationDenied(let app):
            "Claude Chat is not allowed to control \(app). Enable it in System Settings → Privacy & Security → Automation."
        case .script(let message):
            "AppleScript error: \(message)"
        }
    }
}

/// Finds the files the user means: the front Preview document, else the Finder selection.
/// Preview is only queried while it is running — asking it would launch it otherwise.
@MainActor
enum FileContextService {
    private static let previewBundleID = "com.apple.Preview"

    private static let previewScript = """
    tell application id "com.apple.Preview"
        if (count of documents) = 0 then return ""
        try
            return path of front document
        on error
            return ""
        end try
    end tell
    """

    private static let finderScript = """
    tell application id "com.apple.finder"
        set output to ""
        repeat with anItem in (get selection)
            set output to output & POSIX path of (anItem as alias) & linefeed
        end repeat
        return output
    end tell
    """

    static func activeFilePaths() throws -> [String] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let previewRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: previewBundleID).isEmpty

        if frontmost == previewBundleID, let path = try previewDocument() {
            return [path]
        }
        let selection = try finderSelection()
        if !selection.isEmpty { return selection }
        if previewRunning, let path = try previewDocument() {
            return [path]
        }
        throw FileContextError.noFile
    }

    private static func previewDocument() throws -> String? {
        let output = try run(previewScript, app: "Preview")
        let path = output.hasPrefix("file://") ? (URL(string: output)?.path ?? output) : output
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static func finderSelection() throws -> [String] {
        try run(finderScript, app: "Finder")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
    }

    /// The first call per target app shows the macOS automation prompt.
    private static func run(_ source: String, app: String) throws -> String {
        guard let script = NSAppleScript(source: source) else { throw FileContextError.script("Could not compile script.") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 || code == -1744 { throw FileContextError.automationDenied(app: app) }
            throw FileContextError.script(error[NSAppleScript.errorMessage] as? String ?? "Unknown error (\(code))")
        }
        return (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// From Settings: triggers the permission prompts (Finder always runs; Preview only if running).
    static func requestPermissions() -> String {
        var denied: [String] = []
        do { _ = try run(#"tell application id "com.apple.finder" to get name"#, app: "Finder") } catch { denied.append("Finder") }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: previewBundleID).isEmpty {
            do { _ = try run(#"tell application id "com.apple.Preview" to get name"#, app: "Preview") } catch { denied.append("Preview") }
        }
        return denied.isEmpty
            ? "Access granted. (Preview is asked the first time a Preview document is sent.)"
            : "Not allowed: \(denied.joined(separator: ", ")). Enable Claude Chat in System Settings → Privacy & Security → Automation."
    }
}
