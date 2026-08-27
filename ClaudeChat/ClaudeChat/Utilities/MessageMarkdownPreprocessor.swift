import Foundation

enum MessageMarkdownPreprocessor {
    /// Markdown-Absätze brauchen `\n\n`. Einzelne `\n` werden sichtbar als Absatzgrenzen erweitert (außer in Code-Blöcken).
    static func prepareForDisplay(_ content: String) -> String {
        guard content.contains("```") else {
            return expandSingleNewlines(content)
        }

        var result = ""
        var remaining = content
        while let openRange = remaining.range(of: "```") {
            let before = String(remaining[..<openRange.lowerBound])
            result += expandSingleNewlines(before)
            remaining = String(remaining[openRange.lowerBound...])

            guard let closeRange = remaining.range(of: "```", range: remaining.index(remaining.startIndex, offsetBy: 3)..<remaining.endIndex) else {
                result += remaining
                return result
            }
            let fenceEnd = closeRange.upperBound
            result += String(remaining[..<fenceEnd])
            remaining = String(remaining[fenceEnd...])
        }
        result += expandSingleNewlines(remaining)
        return result
    }

    private static func expandSingleNewlines(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(?<!\n)\n(?!\n)",
            with: "\n\n",
            options: .regularExpression
        )
    }
}
