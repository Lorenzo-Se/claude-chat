import Foundation

/// Block-level Markdown structure. Inline formatting (bold, links, `code`) stays in the text
/// and is rendered by `AttributedString(markdown:)`. Shared by chat rendering and speech.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: String, text: String, depth: Int)
    case quote(String)
    case code(language: String, code: String)
    case table([[String]])
    case rule
}

public enum MarkdownParser {
    public static func blocks(from markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [[String]] = []

        func flushText() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
            if !table.isEmpty {
                blocks.append(.table(table))
                table = []
            }
        }

        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1

            if let fence = fenceMarker(trimmed) {
                flushText()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while index < lines.count {
                    let codeLine = lines[index]
                    index += 1
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    code.append(codeLine)
                }
                blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushText()
                continue
            }

            if trimmed.hasPrefix("|") {
                // A non-table line always flushes a pending table, so only text can be pending here.
                if !paragraph.isEmpty || !quote.isEmpty { flushText() }
                if !isTableSeparator(trimmed) {
                    table.append(tableCells(trimmed))
                }
                continue
            } else if !table.isEmpty {
                flushText()
            }

            if let heading = heading(trimmed) {
                flushText()
                blocks.append(heading)
                continue
            }

            if isRule(trimmed) {
                flushText()
                blocks.append(.rule)
                continue
            }

            if let item = listItem(line) {
                flushText()
                blocks.append(item)
                continue
            }

            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flushText() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            // Indented continuation of the previous list item.
            if paragraph.isEmpty, quote.isEmpty, line.hasPrefix("  "),
               case .listItem(let marker, let text, let depth)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, text: text + " " + trimmed, depth: depth)
                continue
            }

            if !quote.isEmpty { flushText() }
            paragraph.append(trimmed)
        }
        flushText()
        return blocks
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes.count, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let body = line.dropFirst(indent.count)

        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            return .listItem(marker: "•", text: body.dropFirst(2).trimmingCharacters(in: .whitespaces), depth: depth)
        }

        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let punctuation = afterDigits.first, punctuation == "." || punctuation == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        return .listItem(
            marker: "\(digits).",
            text: afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces),
            depth: depth
        )
    }

    private static func isTableSeparator(_ trimmed: String) -> Bool {
        trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ trimmed: String) -> [String] {
        var row = trimmed
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

public enum InlineMarkdown {
    public static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
    }

    /// Inline Markdown reduced to its visible characters (`**a**` → `a`, `[b](url)` → `b`).
    public static func plainText(_ text: String) -> String {
        String(attributed(text).characters)
    }
}
