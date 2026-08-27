import Foundation

struct StreamJSONUpdate {
    var textDelta: String?
    var fullText: String?
    var sessionId: String?
    var finalResponse: ClaudeResponse?
    var errorMessage: String?
}

/// Parst newline-delimited JSON-Events von `claude --output-format stream-json`.
final class StreamJSONParser {
    private var buffer = ""

    func append(_ data: Data) -> [StreamJSONUpdate] {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
            return []
        }

        buffer += chunk
        var updates: [StreamJSONUpdate] = []

        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex])
            buffer = String(buffer[buffer.index(after: newlineIndex)...])
            if let update = parseLine(line) {
                updates.append(update)
            }
        }

        return updates
    }

    func flush() -> [StreamJSONUpdate] {
        let line = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard !line.isEmpty, let update = parseLine(line) else { return [] }
        return [update]
    }

    private func parseLine(_ line: String) -> StreamJSONUpdate? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let type = json["type"] as? String
        var update = StreamJSONUpdate()

        if let sessionId = json["session_id"] as? String {
            update.sessionId = sessionId
        }

        switch type {
        case "stream_event":
            if let event = json["event"] as? [String: Any],
               event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String,
               !text.isEmpty {
                update.textDelta = text
            }

        case "assistant":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                let text = content.compactMap { block -> String? in
                    guard block["type"] as? String == "text",
                          let value = block["text"] as? String else { return nil }
                    return value
                }.joined()
                if !text.isEmpty {
                    update.fullText = text
                }
            }

        case "result":
            let isError = json["is_error"] as? Bool ?? false
            update.finalResponse = ClaudeResponse(
                result: json["result"] as? String,
                session_id: json["session_id"] as? String,
                total_cost_usd: json["total_cost_usd"] as? Double,
                duration_ms: json["duration_ms"] as? Int,
                is_error: isError
            )
            if isError {
                update.errorMessage = json["result"] as? String ?? "Unbekannter Fehler"
            }

        case "error":
            update.errorMessage = json["error"] as? String
                ?? json["message"] as? String
                ?? "Unbekannter Fehler"

        default:
            break
        }

        let hasContent = update.textDelta != nil
            || update.fullText != nil
            || update.sessionId != nil
            || update.finalResponse != nil
            || update.errorMessage != nil

        return hasContent ? update : nil
    }
}
