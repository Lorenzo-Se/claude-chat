import Foundation
import Testing
@testable import ClaudeChatCore

@Suite struct ModelTests {
    @Test func decodesLegacySingleAttachment() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"user","content":"hi","timestamp":"2026-01-01T00:00:00Z","attachmentPath":"/tmp/a.png"}"#
        let message = try JSONDecoder.chat.decode(Message.self, from: Data(json.utf8))
        #expect(message.attachments == ["/tmp/a.png"])
    }

    @Test func encodesBothAttachmentKeysForOlderVersions() throws {
        let message = Message(role: .user, content: "x", attachments: ["/a", "/b"])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder.chat.encode(message)) as? [String: Any]
        #expect(object?["attachmentPaths"] as? [String] == ["/a", "/b"])
        #expect(object?["attachmentPath"] as? String == "/a")
    }

    @Test func titleIsSetOnlyOnce() {
        var conversation = Conversation()
        conversation.setTitleIfDefault(from: "  First question\nwith two lines that is definitely longer than forty characters  ")
        #expect(conversation.title == "First question with two lines that is de")
        conversation.setTitleIfDefault(from: "Second")
        #expect(conversation.title.hasPrefix("First"))
    }
}

@Suite struct RepositoryTests {
    private func makeRepository() -> ConversationRepository {
        ConversationRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test func savesLoadsAndDeletes() throws {
        let repository = makeRepository()
        var conversation = Conversation(title: "A")
        conversation.messages.append(Message(role: .user, content: "Hello"))
        var index = try repository.save(conversation, index: [])
        #expect(index.map(\.id) == [conversation.id])
        // ISO-8601 storage drops sub-second precision, so compare content rather than the whole value.
        let loaded = try #require(repository.load(id: conversation.id))
        #expect(loaded.title == "A")
        #expect(loaded.messages.map(\.id) == conversation.messages.map(\.id))
        #expect(repository.loadIndex().map(\.title) == ["A"])

        index = try repository.delete(id: conversation.id, index: index)
        #expect(index.isEmpty)
        #expect(repository.load(id: conversation.id) == nil)
    }

    @Test func rebuildsMissingOrCorruptIndex() throws {
        let repository = makeRepository()
        let older = Conversation(title: "Older", updatedAt: Date(timeIntervalSince1970: 100))
        let newer = Conversation(title: "Newer", updatedAt: Date(timeIntervalSince1970: 200))
        var index = try repository.save(older, index: [])
        index = try repository.save(newer, index: index)

        try Data("not json".utf8).write(to: repository.directory.appendingPathComponent("index.json"))
        #expect(repository.loadIndex().map(\.title) == ["Newer", "Older"])
    }
}

@Suite struct StreamTests {
    @Test func parsesRealCLIEvents() {
        #expect(ClaudeStreamParser.parse(line: #"{"type":"system","subtype":"init","session_id":"s1"}"#) == [.sessionStarted("s1")])
        #expect(ClaudeStreamParser.parse(line: #"{"type":"system","subtype":"hook_started","session_id":"s1"}"#).isEmpty)
        #expect(ClaudeStreamParser.parse(line: #"{"type":"stream_event","event":{"type":"message_start","message":{}},"parent_tool_use_id":null}"#) == [.messageStarted])
        #expect(ClaudeStreamParser.parse(line: #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}},"parent_tool_use_id":null}"#) == [.textDelta("Hi")])
        #expect(ClaudeStreamParser.parse(line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hi"},{"type":"tool_use"}]}}"#) == [.messageText("Hi")])
        #expect(ClaudeStreamParser.parse(line: #"{"duration_ms":1,"type":"result","result":"Done","session_id":"s2","is_error":false}"#)
            == [.result(ClaudeResult(text: "Done", sessionId: "s2", isError: false))])
        #expect(ClaudeStreamParser.parse(line: "garbage").isEmpty)
    }

    @Test func ignoresSubAgentEvents() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"inner"}},"parent_tool_use_id":"toolu_1"}"#
        #expect(ClaudeStreamParser.parse(line: line).isEmpty)
    }

    @Test func accumulatesDeltasWithoutDuplicatingFullMessages() {
        var accumulator = ResponseAccumulator()
        accumulator.apply(.sessionStarted("s1"))
        accumulator.apply(.messageStarted)
        accumulator.apply(.textDelta("Let me check."))
        accumulator.apply(.messageText("Let me check."))
        accumulator.apply(.messageStarted)
        accumulator.apply(.messageText("The answer is 42."))
        #expect(accumulator.text == "Let me check.\n\nThe answer is 42.")
        #expect(accumulator.sessionId == "s1")

        accumulator.apply(.result(ClaudeResult(text: "The answer is 42.", sessionId: "s2", isError: false)))
        #expect(accumulator.finalText == "The answer is 42.")
        #expect(accumulator.sessionId == "s2")
    }

    @Test func finalTextFallsBackToStreamedText() {
        var accumulator = ResponseAccumulator()
        accumulator.apply(.textDelta("partial"))
        accumulator.apply(.result(ClaudeResult(text: nil, sessionId: nil, isError: false)))
        #expect(accumulator.finalText == "partial")
    }
}

@Suite struct CommandTests {
    @Test func promptIsNeverAnArgument() {
        let command = ClaudeCommand(prompt: "-rf secret prompt", sessionId: "abc", model: "opus")
        #expect(!command.arguments.contains("-rf secret prompt"))
        #expect(command.arguments.contains("-p"))
        #expect(command.arguments.split(separator: "--resume").count == 2)
        #expect(command.arguments.last == "opus")
    }

    @Test func omitsResumeAndModelWhenUnset() {
        let arguments = ClaudeCommand(prompt: "x", sessionId: nil, model: nil).arguments
        #expect(!arguments.contains("--resume"))
        #expect(!arguments.contains("--model"))
    }

    @Test func appendsOnlyUnmentionedAttachments() {
        #expect(ClaudeCommand.prompt(text: "", attachments: ["/a.png"]) == "Analyze this file: /a.png")
        #expect(ClaudeCommand.prompt(text: "Look at /a.png", attachments: ["/a.png"]) == "Look at /a.png")
        #expect(ClaudeCommand.prompt(text: "Compare", attachments: ["/a", "/b"]) == "Compare\n\nFile: /a\nFile: /b")
    }

    @Test func classifiesErrors() {
        #expect(ClaudeCommand.isMissingSessionError("No conversation found with session ID: abc"))
        #expect(ClaudeCommand.looksLikeAuthError("Invalid API key · Please run /login"))
        #expect(!ClaudeCommand.looksLikeAuthError("The file login.swift was not found"))
    }
}

@Suite struct TemplateTests {
    @Test func matchesURLPatterns() {
        #expect(PromptTemplates.urlMatches(pattern: "github.com", url: "https://gist.github.com/x"))
        #expect(!PromptTemplates.urlMatches(pattern: "github.com", url: "https://notgithub.com/"))
        #expect(PromptTemplates.urlMatches(pattern: "https://docs.swift.org", url: "https://docs.swift.org/guide"))
        #expect(PromptTemplates.urlMatches(pattern: "youtube.com/watch", url: "https://www.youtube.com/watch?v=1"))
        #expect(!PromptTemplates.urlMatches(pattern: "  ", url: "https://a.com"))
    }

    @Test func pageTextIsNotScannedForPlaceholders() {
        let content = WebsiteContent(title: "T", url: "https://a.com", text: "literal {url} in page")
        #expect(PromptTemplates.website("{url}|{content}", content: content) == "https://a.com|literal {url} in page")
    }

    @Test func picksFirstMatchingOverride() {
        let content = WebsiteContent(title: "", url: "https://github.com/a", text: "x")
        let overrides = [
            WebsiteURLPromptOverride(pattern: "example.com", prompt: "A"),
            WebsiteURLPromptOverride(pattern: "github.com", prompt: "B"),
        ]
        #expect(PromptTemplates.websiteTemplate(for: content, defaultPrompt: "D", overrides: overrides) == "B")
    }

    @Test func fillsFilePlaceholders() {
        let prompt = PromptTemplates.files("{filename}: {paths}", paths: ["/x/a.pdf", "/x/b.pdf"])
        #expect(prompt == "a.pdf: /x/a.pdf\n/x/b.pdf")
    }
}

@Suite struct MarkdownTests {
    @Test func parsesBlocks() {
        let markdown = """
        # Title
        Some **bold**
        text.

        - one
          continued
        2. two

        ```swift
        let x = 1

        print(x)
        ```
        > quoted
        ---
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        #expect(MarkdownParser.blocks(from: markdown) == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold**\ntext."),
            .listItem(marker: "•", text: "one continued", depth: 0),
            .listItem(marker: "2.", text: "two", depth: 0),
            .code(language: "swift", code: "let x = 1\n\nprint(x)"),
            .quote("quoted"),
            .rule,
            .table([["A", "B"], ["1", "2"]]),
        ])
    }

    @Test func unclosedFenceWhileStreamingIsCode() {
        #expect(MarkdownParser.blocks(from: "Intro\n```\nlet a") == [.paragraph("Intro"), .code(language: "", code: "let a")])
    }

    @Test func nestedListDepth() {
        #expect(MarkdownParser.blocks(from: "- a\n  - b") == [
            .listItem(marker: "•", text: "a", depth: 0),
            .listItem(marker: "•", text: "b", depth: 1),
        ])
    }

    @Test func inlinePlainText() {
        #expect(InlineMarkdown.plainText("**Bold** and [link](https://x.com) `code`") == "Bold and link code")
    }
}

@Suite struct SpeechTests {
    @Test func skipsCodeAndSymbols() {
        let markdown = """
        ## Result 🎉
        See **this** at https://www.example.com/path?q=1 and /Users/me/Projects/app/main.swift.

        ```
        rm -rf /
        ```
        - First point
        """
        let segments = SpeechScript.segments(fromMarkdown: markdown, length: .full)
        #expect(segments.map(\.text) == ["Result", "See this at example.com and main.swift.", "First point"])
        #expect(segments[0].pauseAfter > segments[2].pauseAfter)
    }

    @Test func shortModeReadsTwoSentences() {
        let segments = SpeechScript.segments(fromMarkdown: "Erster Satz, z.B. mit Abkürzung. Zweiter Satz! Dritter Satz.", length: .short)
        #expect(segments.map(\.text) == ["Erster Satz, z.B. mit Abkürzung. Zweiter Satz!"])
    }

    @Test func emptyWhenOnlyCode() {
        #expect(SpeechScript.segments(fromMarkdown: "```\ncode\n```", length: .full).isEmpty)
    }

    @Test func detectsLanguage() {
        #expect(SpeechScript.dominantLanguage(of: "Das ist eine Antwort auf Deutsch, die vorgelesen werden soll.") == "de")
        #expect(SpeechScript.dominantLanguage(of: "This is an answer in English that should be read aloud.") == "en")
    }
}

@Suite struct TemporaryFileStoreTests {
    @Test func importsAndPurges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TemporaryFileStore(directory: directory, maxAge: 60)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: source)

        let copy = try store.importCopy(of: source.path)
        #expect(copy.hasSuffix(source.lastPathComponent))
        #expect(FileManager.default.fileExists(atPath: copy))

        store.purgeExpired(now: Date())
        #expect(FileManager.default.fileExists(atPath: copy))
        store.purgeExpired(now: Date().addingTimeInterval(120))
        #expect(!FileManager.default.fileExists(atPath: copy))
    }
}
