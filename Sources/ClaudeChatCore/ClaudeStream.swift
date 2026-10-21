import Foundation

/// Events of interest from `claude -p --output-format stream-json --verbose --include-partial-messages`.
public enum ClaudeEvent: Equatable, Sendable {
    case sessionStarted(String)
    /// A new assistant message (turn) begins; earlier turns are typically tool-use preambles.
    case messageStarted
    case textDelta(String)
    /// Complete text of one assistant message. Only relevant when no deltas were streamed for it.
    case messageText(String)
    case result(ClaudeResult)
}

public struct ClaudeResult: Equatable, Sendable {
    public var text: String?
    public var sessionId: String?
    public var isError: Bool

    public init(text: String?, sessionId: String?, isError: Bool) {
        self.text = text
        self.sessionId = sessionId
        self.isError = isError
    }
}

public enum ClaudeStreamParser {
    /// Parses a single NDJSON line. Events from sub-agents (`parent_tool_use_id != null`) are ignored.
    public static func parse(line: some StringProtocol) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return [] }

        if let parent = json["parent_tool_use_id"], !(parent is NSNull) {
            return []
        }

        switch type {
        case "system":
            if json["subtype"] as? String == "init", let sessionId = json["session_id"] as? String {
                return [.sessionStarted(sessionId)]
            }
            return []

        case "stream_event":
            guard let event = json["event"] as? [String: Any] else { return [] }
            switch event["type"] as? String {
            case "message_start":
                return [.messageStarted]
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String, !text.isEmpty else { return [] }
                return [.textDelta(text)]
            default:
                return []
            }

        case "assistant":
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            let text = content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            return text.isEmpty ? [] : [.messageText(text)]

        case "result":
            return [.result(ClaudeResult(
                text: json["result"] as? String,
                sessionId: json["session_id"] as? String,
                isError: json["is_error"] as? Bool ?? false
            ))]

        default:
            return []
        }
    }
}

/// Folds stream events into the text shown while a response is streaming.
public struct ResponseAccumulator: Sendable {
    public private(set) var text = ""
    public private(set) var sessionId: String?
    public private(set) var result: ClaudeResult?

    private var currentMessageHasDeltas = false
    private var needsSeparator = false

    public init() {}

    /// Returns true if the visible text changed.
    @discardableResult
    public mutating func apply(_ event: ClaudeEvent) -> Bool {
        switch event {
        case .sessionStarted(let id):
            sessionId = id
            return false
        case .messageStarted:
            currentMessageHasDeltas = false
            needsSeparator = !text.isEmpty
            return false
        case .textDelta(let delta):
            appendText(delta)
            currentMessageHasDeltas = true
            return true
        case .messageText(let full):
            guard !currentMessageHasDeltas else { return false }
            appendText(full)
            currentMessageHasDeltas = true
            return true
        case .result(let result):
            self.result = result
            if let id = result.sessionId { sessionId = id }
            return false
        }
    }

    /// Final answer: the CLI's `result` (last turn) when present, otherwise everything streamed.
    public var finalText: String {
        if let resultText = result?.text, !resultText.isEmpty, result?.isError == false {
            return resultText
        }
        return text
    }

    private mutating func appendText(_ value: String) {
        if needsSeparator {
            text += "\n\n"
            needsSeparator = false
        }
        text += value
    }
}
