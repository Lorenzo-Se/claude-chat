import Foundation

/// Arguments for one headless `claude` invocation. The prompt is written to stdin, never passed as argv,
/// so long website content and prompts starting with "-" are safe.
public struct ClaudeCommand: Equatable, Sendable {
    /// Headless settings: no interactive dialogs, tools pre-approved.
    /// Not `--dangerously-skip-permissions` — that shows a bypass dialog the CLI may ignore.
    static let headlessSettingsJSON = """
    {"permissions":{"defaultMode":"dontAsk","allow":["Bash(*)","Read(*)","Edit(*)","Write(*)","Glob(*)","Grep(*)","WebFetch(*)","WebSearch(*)","Task(*)","NotebookEdit(*)","MultiEdit(*)","TodoWrite(*)","Agent(*)","mcp__*"]}}
    """

    public var prompt: String
    public var sessionId: String?
    public var model: String?

    public init(prompt: String, sessionId: String?, model: String?) {
        self.prompt = prompt
        self.sessionId = sessionId
        self.model = model
    }

    public var arguments: [String] {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", "dontAsk",
            "--settings", Self.headlessSettingsJSON,
        ]
        if let sessionId, !sessionId.isEmpty {
            args += ["--resume", sessionId]
        }
        if let model, !model.isEmpty {
            args += ["--model", model]
        }
        return args
    }

    /// Adds attachment paths the prompt does not already mention, so Claude can `Read` them.
    public static func prompt(text: String, attachments: [String]) -> String {
        let missing = attachments.filter { !text.contains($0) }
        guard !missing.isEmpty else { return text }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileLines = missing.map { "File: \($0)" }.joined(separator: "\n")
        if trimmed.isEmpty {
            return missing.count == 1
                ? "Analyze this file: \(missing[0])"
                : "Analyze these files:\n\(fileLines)"
        }
        return "\(trimmed)\n\n\(fileLines)"
    }

    /// Error text from the CLI that means the stored `--resume` session no longer exists.
    public static func isMissingSessionError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("no conversation found") || lowered.contains("session not found")
    }

    public static func looksLikeAuthError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("not logged in")
            || lowered.contains("please run /login")
            || lowered.contains("invalid api key")
            || lowered.contains("authentication")
    }
}
