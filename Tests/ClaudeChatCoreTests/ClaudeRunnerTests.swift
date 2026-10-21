import Foundation
import Testing
@testable import ClaudeChatCore

/// Runs `ClaudeRunner` against small shell scripts that imitate the `claude` CLI.
@Suite struct ClaudeRunnerTests {
    private func fakeCLI(_ body: String) throws -> CLIEnvironment {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return CLIEnvironment(executable: url.path, path: nil)
    }

    private func collect(
        _ environment: CLIEnvironment,
        prompt: String = "hi",
        timeout: TimeInterval = ClaudeRunner.defaultInactivityTimeout
    ) async -> (events: [ClaudeEvent], error: Error?) {
        var events: [ClaudeEvent] = []
        do {
            let command = ClaudeCommand(prompt: prompt, sessionId: nil, model: nil)
            for try await event in ClaudeRunner.run(command, environment: environment, inactivityTimeout: timeout) {
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    @Test func streamsEventsAndReadsPromptFromStdin() async throws {
        let cli = try fakeCLI("""
        prompt=$(cat)
        echo '{"type":"system","subtype":"init","session_id":"s1"}'
        printf '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}},"parent_tool_use_id":null}\\n' "$prompt"
        echo '{"type":"result","result":"done","session_id":"s1","is_error":false}'
        """)
        let (events, error) = await collect(cli, prompt: "-starts with dash")
        #expect(error == nil)
        #expect(events == [
            .sessionStarted("s1"),
            .textDelta("-starts with dash"),
            .result(ClaudeResult(text: "done", sessionId: "s1", isError: false)),
        ])
    }

    @Test func largePromptDoesNotDeadlock() async throws {
        let cli = try fakeCLI("""
        count=$(wc -c | tr -d ' ')
        printf '{"type":"result","result":"%s","is_error":false}\\n' "$count"
        """)
        let prompt = String(repeating: "x", count: 300_000)
        let (events, error) = await collect(cli, prompt: prompt)
        #expect(error == nil)
        #expect(events == [.result(ClaudeResult(text: "300000", sessionId: nil, isError: false))])
    }

    @Test func mapsMissingSession() async throws {
        let cli = try fakeCLI("cat >/dev/null; echo 'No conversation found with session ID: abc' >&2; exit 1")
        let (_, error) = await collect(cli)
        #expect((error as? ClaudeRunError).map { if case .missingSession = $0 { true } else { false } } == true)
    }

    @Test func mapsErrorResultToAuthError() async throws {
        let cli = try fakeCLI("""
        cat >/dev/null
        echo '{"type":"result","result":"Invalid API key · Please run /login","is_error":true}'
        exit 1
        """)
        let (_, error) = await collect(cli)
        #expect((error as? ClaudeRunError).map { if case .notLoggedIn = $0 { true } else { false } } == true)
    }

    @Test func reportsGenericFailureWithStderr() async throws {
        let cli = try fakeCLI("cat >/dev/null; echo 'boom' >&2; exit 3")
        let (_, error) = await collect(cli)
        #expect(error as? ClaudeRunError == .failed("boom"))
    }

    @Test func stopsSilentProcessAfterInactivity() async throws {
        // No output at all, so the result does not depend on how fast the process starts.
        let cli = try fakeCLI("cat >/dev/null; exec sleep 30")
        let start = Date()
        let (events, error) = await collect(cli, timeout: 1)
        #expect(events.isEmpty)
        #expect(error as? ClaudeRunError == .timedOut(minutes: 1))
        #expect(Date().timeIntervalSince(start) < 15)
    }

    @Test func cancellingTheConsumerKillsTheProcess() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-pid-\(UUID().uuidString)")
        let cli = try fakeCLI("echo $$ > '\(marker.path)'; cat >/dev/null; exec sleep 30")
        let task = Task { await collect(cli) }
        // Process start can take a while when many tests spawn processes in parallel.
        var pid: Int32?
        for _ in 0..<100 where pid == nil {
            try await Task.sleep(for: .milliseconds(100))
            pid = (try? String(contentsOf: marker, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let runningPID = try #require(pid)
        task.cancel()
        let (_, error) = await task.value
        #expect(error == nil, "a cancelled consumer sees the stream end")

        for _ in 0..<50 where kill(runningPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(kill(runningPID, 0) != 0, "fake CLI should have been terminated")
    }

    @Test func missingExecutableFails() async {
        let (_, error) = await collect(CLIEnvironment(executable: "/nonexistent/claude", path: nil))
        #expect((error as? ClaudeRunError).map { if case .failed = $0 { true } else { false } } == true)
    }
}

/// Talks to the real `claude` CLI (uses subscription quota). Run with: CLAUDE_CHAT_LIVE_TEST=1 swift test --filter Live
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDE_CHAT_LIVE_TEST"] != nil))
struct LiveCLITests {
    @Test func streamsAndResumesSession() async throws {
        let environment = try await CLIResolver().resolve(override: "")

        var first = ResponseAccumulator()
        for try await event in ClaudeRunner.run(
            ClaudeCommand(prompt: "Remember the word 'kiwi'. Reply with exactly: ok", sessionId: nil, model: "haiku"),
            environment: environment
        ) {
            first.apply(event)
        }
        let sessionId = try #require(first.sessionId)
        #expect(first.finalText.lowercased().contains("ok"))

        var second = ResponseAccumulator()
        for try await event in ClaudeRunner.run(
            ClaudeCommand(prompt: "Which word did I ask you to remember? Reply with just the word.", sessionId: sessionId, model: "haiku"),
            environment: environment
        ) {
            second.apply(event)
        }
        #expect(second.finalText.lowercased().contains("kiwi"))
    }

    @Test func unknownSessionIsReportedAsMissing() async throws {
        let environment = try await CLIResolver().resolve(override: "")
        do {
            for try await _ in ClaudeRunner.run(
                ClaudeCommand(prompt: "hi", sessionId: UUID().uuidString.lowercased(), model: "haiku"),
                environment: environment
            ) {}
            Issue.record("expected an error")
        } catch let error as ClaudeRunError {
            guard case .missingSession = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
    }
}
