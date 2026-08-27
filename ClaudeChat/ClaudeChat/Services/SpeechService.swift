import AVFoundation
import Foundation

enum SpeechTextShrunker {
  private static let maxCharacters = 500
  private static let maxSentences = 2

  static func shrinkForSpeech(_ text: String) -> String {
    var cleaned = stripMarkdown(text)
    cleaned = cleaned
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !cleaned.isEmpty else { return "" }

    if cleaned.count <= maxCharacters {
      return extractLeadingSentences(from: cleaned)
    }

    let shortened = extractLeadingSentences(from: cleaned)
    if shortened.count <= maxCharacters {
      return shortened
    }

    return truncateAtWordBoundary(shortened, limit: maxCharacters)
  }

  private static func stripMarkdown(_ text: String) -> String {
    var result = text

    // Fenced code blocks
    result = result.replacingOccurrences(
      of: #"```[\s\S]*?```"#,
      with: "",
      options: .regularExpression
    )
    // Inline code
    result = result.replacingOccurrences(
      of: #"`[^`]+`"#,
      with: "",
      options: .regularExpression
    )
    // Links: [label](url) -> label
    result = result.replacingOccurrences(
      of: #"\[([^\]]+)\]\([^)]+\)"#,
      with: "$1",
      options: .regularExpression
    )
    // Images
    result = result.replacingOccurrences(
      of: #"!\[[^\]]*\]\([^)]+\)"#,
      with: "",
      options: .regularExpression
    )
    // Headings / blockquotes / list markers (multiline)
    result = result.replacingOccurrences(
      of: #"(?m)^#{1,6}\s+"#,
      with: "",
      options: .regularExpression
    )
    result = result.replacingOccurrences(
      of: #"(?m)^>\s?"#,
      with: "",
      options: .regularExpression
    )
    result = result.replacingOccurrences(
      of: #"(?m)^[-*+]\s+"#,
      with: "",
      options: .regularExpression
    )
    result = result.replacingOccurrences(
      of: #"(?m)^\d+\.\s+"#,
      with: "",
      options: .regularExpression
    )
    // Bold / italic markers
    result = result.replacingOccurrences(of: #"[*_~]"#, with: "", options: .regularExpression)

    return result
  }

  private static func extractLeadingSentences(from text: String) -> String {
    let pattern = #"[^.!?…]+[.!?…]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return String(text.prefix(maxCharacters))
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = regex.matches(in: text, range: range)
    guard !matches.isEmpty else {
      return String(text.prefix(maxCharacters))
    }

    let sentenceCount = min(maxSentences, matches.count)
    let selected = matches.prefix(sentenceCount).compactMap { match -> String? in
      guard let swiftRange = Range(match.range, in: text) else { return nil }
      return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return selected.joined(separator: " ")
  }

  private static func truncateAtWordBoundary(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    let index = text.index(text.startIndex, offsetBy: limit)
    let prefix = String(text[..<index])
    if let lastSpace = prefix.lastIndex(of: " ") {
      return String(prefix[..<lastSpace]) + "…"
    }
    return prefix + "…"
  }
}

@MainActor
final class SpeechService {
  static let shared = SpeechService()

  private let synthesizer = AVSpeechSynthesizer()

  private init() {}

  func speak(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }

    let utterance = AVSpeechUtterance(string: trimmed)
    utterance.voice = AVSpeechSynthesisVoice(language: "de-DE")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    synthesizer.speak(utterance)
  }

  func stop() {
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
  }
}
