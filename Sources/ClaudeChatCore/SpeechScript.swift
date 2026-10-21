import Foundation
import NaturalLanguage

public enum SpeechLength: String, CaseIterable, Identifiable, Sendable {
    /// First two sentences — a quick spoken answer.
    case short
    /// The whole response, block by block.
    case full

    public var id: String { rawValue }
}

public struct SpeechSegment: Equatable, Sendable {
    public var text: String
    /// Pause after this segment, in seconds — gives headings and paragraphs a natural rhythm.
    public var pauseAfter: Double

    public init(text: String, pauseAfter: Double) {
        self.text = text
        self.pauseAfter = pauseAfter
    }
}

/// Turns a Markdown response into text that sounds natural when spoken:
/// no code blocks, no Markdown symbols, no emoji, URLs reduced to their host, paths to their file name.
public enum SpeechScript {
    static let shortMaxSentences = 2
    static let shortMaxCharacters = 500

    public static func segments(fromMarkdown markdown: String, length: SpeechLength) -> [SpeechSegment] {
        let full = MarkdownParser.blocks(from: markdown).flatMap(segments(for:))
        switch length {
        case .full:
            return full
        case .short:
            let joined = full.map(\.text).joined(separator: " ")
            let summary = leadingSentences(of: joined)
            return summary.isEmpty ? [] : [SpeechSegment(text: summary, pauseAfter: 0)]
        }
    }

    /// BCP-47 language code of the text (e.g. "de", "en"), if it can be determined.
    public static func dominantLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        return recognizer.dominantLanguage?.rawValue
    }

    private static func segments(for block: MarkdownBlock) -> [SpeechSegment] {
        switch block {
        case .heading(_, let text):
            return segment(text, pause: 0.4)
        case .paragraph(let text), .quote(let text):
            return segment(text, pause: 0.25)
        case .listItem(_, let text, _):
            return segment(text, pause: 0.15)
        case .table(let rows):
            return rows.flatMap { segment($0.filter { !$0.isEmpty }.joined(separator: ", "), pause: 0.15) }
        case .code, .rule:
            return []
        }
    }

    private static func segment(_ markdown: String, pause: Double) -> [SpeechSegment] {
        let text = clean(markdown)
        return text.isEmpty ? [] : [SpeechSegment(text: text, pauseAfter: pause)]
    }

    static func clean(_ markdown: String) -> String {
        var text = InlineMarkdown.plainText(markdown)
        text = replaceMatches(in: text, pattern: #"https?://[^\s)\]>]+"#) { match in
            URL(string: match)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        }
        text = replaceMatches(in: text, pattern: #"(?<![\w.])(?:~|\.{1,2})?(?:/[\w.\-]+){2,}/?"#) { match in
            (match as NSString).lastPathComponent
        }
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !isEmoji($0) }))
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        // Digits and # are "emoji" too (keycap bases), so only presentation emoji and pictograph planes count.
        scalar.properties.isEmojiPresentation
            || (scalar.properties.isEmoji && scalar.value >= 0x1F000)
            || [0xFE0F, 0x200D, 0x20E3].contains(scalar.value)
    }

    static func leadingSentences(of text: String) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append(text[range].trimmingCharacters(in: .whitespacesAndNewlines))
            return sentences.count < shortMaxSentences
        }
        let summary = sentences.filter { !$0.isEmpty }.joined(separator: " ")
        return truncate(summary.isEmpty ? text : summary, limit: shortMaxCharacters)
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit))
        guard let lastSpace = prefix.lastIndex(of: " ") else { return prefix + "…" }
        return String(prefix[..<lastSpace]) + "…"
    }

    private static func replaceMatches(in text: String, pattern: String, with transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(nsText.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }
}
