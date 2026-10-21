import Foundation

public struct WebsiteContent: Equatable, Sendable {
    public let title: String
    public let url: String
    public let text: String

    public init(title: String, url: String, text: String) {
        self.title = title
        self.url = url
        self.text = text
    }
}

public struct WebsiteURLPromptOverride: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var pattern: String
    public var prompt: String

    public init(id: UUID = UUID(), pattern: String = "", prompt: String = "") {
        self.id = id
        self.pattern = pattern
        self.prompt = prompt
    }
}

public enum PromptTemplates {
    public static let defaultScreenshot = "Analyze this screenshot: {path}"
    public static let defaultFile = "Analyze the attached file."
    public static let defaultWebsite = """
    Analyze this website:
    URL: {url}
    Title: {title}
    Content:
    {content}
    """

    public static func screenshot(_ template: String, path: String, userText: String = "") -> String {
        template
            .replacingOccurrences(of: "{path}", with: path)
            .replacingOccurrences(of: "{userText}", with: userText)
    }

    public static func files(_ template: String, paths: [String], userText: String = "") -> String {
        let primary = paths.first ?? ""
        return template
            .replacingOccurrences(of: "{paths}", with: paths.joined(separator: "\n"))
            .replacingOccurrences(of: "{path}", with: primary)
            .replacingOccurrences(of: "{filename}", with: (primary as NSString).lastPathComponent)
            .replacingOccurrences(of: "{userText}", with: userText)
    }

    public static func website(_ template: String, content: WebsiteContent) -> String {
        // {content} last: page text must not be scanned for the other placeholders.
        template
            .replacingOccurrences(of: "{url}", with: content.url)
            .replacingOccurrences(of: "{title}", with: content.title)
            .replacingOccurrences(of: "{content}", with: content.text)
    }

    public static func websiteTemplate(
        for content: WebsiteContent,
        defaultPrompt: String,
        overrides: [WebsiteURLPromptOverride]
    ) -> String {
        overrides.first { urlMatches(pattern: $0.pattern, url: content.url) }?.prompt ?? defaultPrompt
    }

    /// `https://…` → prefix match, `host/path` → substring match, `host` → host or subdomain match.
    public static func urlMatches(pattern: String, url: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !pattern.isEmpty else { return false }
        let url = url.lowercased()

        if pattern.hasPrefix("http://") || pattern.hasPrefix("https://") {
            return url.hasPrefix(pattern)
        }
        if pattern.contains("/") {
            return url.contains(pattern)
        }
        guard let host = URL(string: url)?.host?.lowercased() else {
            return url.contains(pattern)
        }
        return host == pattern || host.hasSuffix("." + pattern)
    }

    /// Plain page content for the input field when no system prompt is used.
    public static func rawWebsite(_ content: WebsiteContent) -> String {
        var header: [String] = []
        if !content.url.isEmpty { header.append("URL: \(content.url)") }
        if !content.title.isEmpty { header.append("Title: \(content.title)") }
        return header.isEmpty ? content.text : header.joined(separator: "\n") + "\n\n" + content.text
    }

    /// Compact chat bubble text for an automatically sent website prompt.
    public static func websiteSummary(_ content: WebsiteContent) -> String {
        [content.title.isEmpty ? "Website" : content.title, content.url]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
