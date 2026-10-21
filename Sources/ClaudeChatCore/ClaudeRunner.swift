import Foundation

public enum ClaudeRunError: LocalizedError, Equatable, Sendable {
    case cliNotFound
    case notLoggedIn(String)
    case missingSession(String)
    case failed(String)
    case timedOut(minutes: Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Claude CLI not found. Install Claude Code and run `claude login` in the terminal, or set the CLI path in Settings."
        case .notLoggedIn(let detail):
            "Claude CLI is not logged in. Run `claude login` in the terminal.\n\n\(detail)"
        case .missingSession(let detail), .failed(let detail):
            detail
        case .timedOut(let minutes):
            "No output from Claude for \(minutes) minutes — request stopped."
        case .cancelled:
            "Request cancelled."
        }
    }
}

/// Where `claude` lives and the PATH of the user's login shell (so tools Claude runs find git, brew, node, …).
public struct CLIEnvironment: Sendable {
    public let executable: String
    public let path: String?

    public init(executable: String, path: String?) {
        self.executable = executable
        self.path = path
    }
}

public actor CLIResolver {
    private var cached: CLIEnvironment?

    public init() {}

    public func resolve(override: String) async throws -> CLIEnvironment {
        let override = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else { throw ClaudeRunError.cliNotFound }
            return CLIEnvironment(executable: override, path: try? await loginShell().path)
        }
        if let cached, FileManager.default.isExecutableFile(atPath: cached.executable) {
            return cached
        }
        let shell = try? await loginShell()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [shell?.executable, "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ClaudeRunError.cliNotFound
        }
        let resolved = CLIEnvironment(executable: executable, path: shell?.path)
        cached = resolved
        return resolved
    }

    public func invalidate() {
        cached = nil
    }

    /// Asks the user's login shell (nvm, Homebrew, … are set up there) for `claude` and `$PATH`.
    private func loginShell() async throws -> (executable: String?, path: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let output = try await ProcessOutput.run(
            executable: shell,
            arguments: ["-l", "-c", #"printf '%s\n%s' "$(command -v claude)" "$PATH""#],
            timeout: 10
        )
        let lines = output.components(separatedBy: "\n")
        let executable = lines.first.flatMap { $0.hasPrefix("/") ? $0 : nil }
        let path = lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil
        return (executable, path)
    }
}

enum ProcessOutput {
    /// Runs a short helper process and returns stdout. Killed after `timeout` seconds.
    static func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.terminationHandler = { _ in
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// Runs one `claude -p` request and streams its events. Cancelling the consuming task stops the process.
public enum ClaudeRunner {
    public static let defaultInactivityTimeout: TimeInterval = 10 * 60

    public static func run(
        _ command: ClaudeCommand,
        environment: CLIEnvironment,
        inactivityTimeout: TimeInterval = defaultInactivityTimeout
    ) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: environment.executable)
            process.arguments = command.arguments
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.environment = processEnvironment(path: environment.path)

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            let state = RunState()

            @Sendable func emit(_ lines: [Data]) {
                for line in lines {
                    for event in ClaudeStreamParser.parse(line: String(decoding: line, as: UTF8.self)) {
                        if case .result(let result) = event { state.result = result }
                        continuation.yield(event)
                    }
                }
            }

            /// Finishes once both stdout is closed and the process has exited.
            @Sendable func finishIfDone() {
                guard let status = state.claimCompletion() else { return }
                if let error = completionError(status: status, state: state, inactivityTimeout: inactivityTimeout) {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }

            @Sendable func closeOutput() {
                stdout.fileHandleForReading.readabilityHandler = nil
                emit(state.closeOutput())
                finishIfDone()
            }

            // readabilityHandler delivers data as soon as it arrives (FileHandle.bytes buffers pipes).
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { closeOutput() } else { emit(state.appendStdout(data)) }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { state.appendStderr(data) }
            }
            process.terminationHandler = { finished in
                state.markExited(finished.terminationStatus)
                finishIfDone()
                // A child process that inherited stdout could keep it open forever; stop waiting after a grace period.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if !state.isOutputClosed { closeOutput() }
                }
            }

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    state.cancelled = true
                    stop(process)
                }
            }

            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: ClaudeRunError.failed("Could not start Claude CLI: \(error.localizedDescription)"))
                return
            }

            // Blocking write on a dispatch thread (not the Swift concurrency pool). write(contentsOf:) throws
            // on a closed pipe instead of raising like write(_:).
            DispatchQueue.global(qos: .userInitiated).async {
                try? stdin.fileHandleForWriting.write(contentsOf: Data(command.prompt.utf8))
                try? stdin.fileHandleForWriting.close()
            }

            @Sendable func watch() {
                let interval = min(5, max(0.1, inactivityTimeout / 4))
                DispatchQueue.global().asyncAfter(deadline: .now() + interval) {
                    guard !state.isCompleted, process.isRunning else { return }
                    if state.secondsSinceActivity > inactivityTimeout {
                        state.timedOut = true
                        stop(process)
                    } else {
                        watch()
                    }
                }
            }
            watch()
        }
    }

    private static func completionError(status: Int32, state: RunState, inactivityTimeout: TimeInterval) -> ClaudeRunError? {
        if state.cancelled { return .cancelled }
        if state.timedOut { return .timedOut(minutes: max(1, Int(inactivityTimeout / 60))) }

        let result = state.result
        guard status != 0 || result?.isError == true else { return nil }

        // An error result may carry no text (e.g. unknown --resume session); the reason is then on stderr.
        let messages = [result?.isError == true ? result?.text : nil, state.stderrText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let detail = messages.first ?? "Claude CLI exited with code \(status)."
        let all = messages.joined(separator: "\n")
        if ClaudeCommand.isMissingSessionError(all) { return .missingSession(detail) }
        if ClaudeCommand.looksLikeAuthError(all) { return .notLoggedIn(detail) }
        return .failed(String(detail.prefix(2000)))
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private static func processEnvironment(path: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSHomeDirectory()
        environment["USER"] = NSUserName()
        if let path { environment["PATH"] = path }
        // When launched from a Claude Code terminal, these make the CLI think it is nested.
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        return environment
    }
}

/// Shared between the pipe handlers, termination handler and watchdog of one run.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrData = Data()
    private var lastActivity = Date()
    private var status: Int32?
    private var outputClosed = false
    private var completed = false
    private var _cancelled = false
    private var _timedOut = false
    private var _result: ClaudeResult?

    var cancelled: Bool {
        get { locked { _cancelled } }
        set { locked { _cancelled = newValue } }
    }
    var timedOut: Bool {
        get { locked { _timedOut } }
        set { locked { _timedOut = newValue } }
    }
    var result: ClaudeResult? {
        get { locked { _result } }
        set { locked { _result = newValue } }
    }
    var isOutputClosed: Bool { locked { outputClosed } }
    var isCompleted: Bool { locked { completed } }
    var secondsSinceActivity: TimeInterval { locked { Date().timeIntervalSince(lastActivity) } }
    var stderrText: String {
        locked { String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Buffers stdout and returns every complete line.
    func appendStdout(_ data: Data) -> [Data] {
        locked {
            guard !outputClosed else { return [] }
            lastActivity = Date()
            stdoutBuffer.append(data)
            var lines: [Data] = []
            while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                lines.append(Data(stdoutBuffer[stdoutBuffer.startIndex..<newline]))
                stdoutBuffer = Data(stdoutBuffer[stdoutBuffer.index(after: newline)...])
            }
            return lines
        }
    }

    /// Marks stdout as finished and returns a trailing line without newline, if any.
    func closeOutput() -> [Data] {
        locked {
            guard !outputClosed else { return [] }
            outputClosed = true
            defer { stdoutBuffer = Data() }
            return stdoutBuffer.isEmpty ? [] : [stdoutBuffer]
        }
    }

    func appendStderr(_ data: Data) {
        locked {
            lastActivity = Date()
            if stderrData.count < 64 * 1024 { stderrData.append(data) }
        }
    }

    func markExited(_ code: Int32) {
        locked { status = code }
    }

    /// Returns the exit status exactly once, when output is closed and the process has exited.
    func claimCompletion() -> Int32? {
        locked {
            guard !completed, outputClosed, let status else { return nil }
            completed = true
            return status
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
