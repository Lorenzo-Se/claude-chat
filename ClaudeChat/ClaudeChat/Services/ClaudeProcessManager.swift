import Foundation

struct ClaudeResponse: Decodable {
    let result: String?
    let session_id: String?
    let total_cost_usd: Double?
    let duration_ms: Int?
    let is_error: Bool?

    var isError: Bool { is_error == true }
}

enum ClaudeProcessError: LocalizedError {
    case cliNotFound
    case processFailed(exitCode: Int32, stderr: String)
    case parseFailed(String)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Claude CLI not found. Please run `claude login` in the terminal."
        case .processFailed(let code, let stderr):
            return "Claude process failed (exit \(code)): \(stderr)"
        case .parseFailed(let detail):
            return "Could not read response: \(detail)"
        case .timeout:
            return "Timed out after 120 seconds."
        case .cancelled:
            return "Request cancelled."
        }
    }
}

@MainActor
final class ClaudeProcessManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var runningConversationIds: Set<UUID> = []

    private var activeProcesses: [UUID: Process] = [:]
    private var cancelledConversationIds: Set<UUID> = []
    private var timedOutConversationIds: Set<UUID> = []
    private let timeoutSeconds: TimeInterval = 120

    /// Headless settings: no interactive dialogs, tools pre-approved.
    /// No `--dangerously-skip-permissions` — that shows a bypass dialog you can reject,
    /// while Claude may continue anyway.
    private static let headlessSettingsJSON = """
    {"permissions":{"defaultMode":"dontAsk","allow":["Bash(*)","Read(*)","Edit(*)","Write(*)","Glob(*)","Grep(*)","WebFetch(*)","WebSearch(*)","Task(*)","NotebookEdit(*)","MultiEdit(*)","TodoWrite(*)","Agent(*)","mcp__*"]}}
    """

    func send(
        prompt: String,
        conversationId: UUID,
        sessionId: String?,
        attachmentPath: String? = nil,
        model: String? = nil,
        streamingEnabled: Bool? = nil,
        onStreamUpdate: ((String) -> Void)? = nil
    ) async throws -> ClaudeResponse {
        let effectiveModel = model ?? AppSettings.shared.model.cliValue
        let effectiveStreaming = streamingEnabled ?? AppSettings.shared.streamingEnabled

        guard activeProcesses[conversationId] == nil else {
            throw ClaudeProcessError.processFailed(exitCode: -1, stderr: "A request is already active for this conversation.")
        }

        let cliPath: String
        do {
            cliPath = try await ClaudeCLIResolver.resolvedPath()
        } catch {
            throw ClaudeProcessError.cliNotFound
        }

        runningConversationIds.insert(conversationId)
        isRunning = !runningConversationIds.isEmpty

        defer {
            runningConversationIds.remove(conversationId)
            isRunning = !runningConversationIds.isEmpty
        }

        let effectivePrompt = Self.buildPrompt(text: prompt, attachmentPath: attachmentPath)

        return try await withTaskCancellationHandler {
            try await runProcess(
                cliPath: cliPath,
                prompt: effectivePrompt,
                conversationId: conversationId,
                sessionId: sessionId,
                attachmentPath: attachmentPath,
                model: effectiveModel,
                streamingEnabled: effectiveStreaming,
                onStreamUpdate: onStreamUpdate
            )
        } onCancel: {
            Task { @MainActor in
                self.terminate(conversationId: conversationId)
            }
        }
    }

    func terminate(conversationId: UUID) {
        cancelledConversationIds.insert(conversationId)
        activeProcesses[conversationId]?.terminate()
    }

    func terminateAll() {
        for conversationId in activeProcesses.keys {
            cancelledConversationIds.insert(conversationId)
        }
        for process in activeProcesses.values {
            process.terminate()
        }
    }

    static func buildPrompt(text: String, attachmentPath: String?) -> String {
        guard let attachmentPath else { return text }

        if text.contains(attachmentPath) {
            return text
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Analyze this file: \(attachmentPath)"
        }
        return "\(trimmed)\n\nFile: \(attachmentPath)"
    }

    private func runProcess(
        cliPath: String,
        prompt: String,
        conversationId: UUID,
        sessionId: String?,
        attachmentPath: String?,
        model: String?,
        streamingEnabled: Bool,
        onStreamUpdate: ((String) -> Void)?
    ) async throws -> ClaudeResponse {
        if streamingEnabled {
            try await runStreamingProcess(
                cliPath: cliPath,
                prompt: prompt,
                conversationId: conversationId,
                sessionId: sessionId,
                attachmentPath: attachmentPath,
                model: model,
                onStreamUpdate: onStreamUpdate
            )
        } else {
            try await runBlockingJSONProcess(
                cliPath: cliPath,
                prompt: prompt,
                conversationId: conversationId,
                sessionId: sessionId,
                attachmentPath: attachmentPath,
                model: model
            )
        }
    }

    private func runBlockingJSONProcess(
        cliPath: String,
        prompt: String,
        conversationId: UUID,
        sessionId: String?,
        attachmentPath: String?,
        model: String?
    ) async throws -> ClaudeResponse {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)

            var arguments = [
                "-p", prompt,
                "--output-format", "json",
                "--permission-mode", "dontAsk",
                "--settings", Self.headlessSettingsJSON
            ]

            if attachmentPath != nil {
                arguments.append(contentsOf: ["--allowedTools", "Read"])
            }

            if let sessionId {
                arguments.append(contentsOf: ["--resume", sessionId])
            }

            if let model, !model.isEmpty {
                arguments.append(contentsOf: ["--model", model])
            }

            process.arguments = arguments
            configureProcessEnvironment(process)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = stdinPipe
            try? stdinPipe.fileHandleForWriting.close()

            activeProcesses[conversationId] = process

            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if process.isRunning {
                    timedOutConversationIds.insert(conversationId)
                    process.terminate()
                }
            }

            process.terminationHandler = { [weak self] proc in
                timeoutTask.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                Task { @MainActor in
                    self?.activeProcesses.removeValue(forKey: conversationId)

                    let wasCancelled = self?.cancelledConversationIds.remove(conversationId) != nil
                    let wasTimeout = self?.timedOutConversationIds.remove(conversationId) != nil

                    if Task.isCancelled || wasCancelled {
                        continuation.resume(throwing: ClaudeProcessError.cancelled)
                        return
                    }

                    if wasTimeout {
                        continuation.resume(throwing: ClaudeProcessError.timeout)
                        return
                    }

                    guard proc.terminationStatus == 0 else {
                        if stderr.contains("not logged in") || stderr.contains("login") {
                            continuation.resume(throwing: ClaudeProcessError.cliNotFound)
                            return
                        }
                        continuation.resume(throwing: ClaudeProcessError.processFailed(
                            exitCode: proc.terminationStatus,
                            stderr: stderr.isEmpty ? stdout : stderr
                        ))
                        return
                    }

                    guard let jsonData = stdoutData.nonEmpty,
                          let response = try? JSONDecoder().decode(ClaudeResponse.self, from: jsonData) else {
                        continuation.resume(throwing: ClaudeProcessError.parseFailed(
                            stderr.isEmpty ? "No JSON response received" : stderr
                        ))
                        return
                    }

                    if response.isError {
                        continuation.resume(throwing: ClaudeProcessError.processFailed(
                            exitCode: 1,
                            stderr: response.result ?? "Unknown error"
                        ))
                    } else {
                        continuation.resume(returning: response)
                    }
                }
            }

            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                activeProcesses.removeValue(forKey: conversationId)
                continuation.resume(throwing: ClaudeProcessError.processFailed(
                    exitCode: -1,
                    stderr: error.localizedDescription
                ))
            }
        }
    }

    private func runStreamingProcess(
        cliPath: String,
        prompt: String,
        conversationId: UUID,
        sessionId: String?,
        attachmentPath: String?,
        model: String?,
        onStreamUpdate: ((String) -> Void)?
    ) async throws -> ClaudeResponse {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)

            var arguments = [
                "-p", prompt,
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--permission-mode", "dontAsk",
                "--settings", Self.headlessSettingsJSON
            ]

            if attachmentPath != nil {
                arguments.append(contentsOf: ["--allowedTools", "Read"])
            }

            if let sessionId {
                arguments.append(contentsOf: ["--resume", sessionId])
            }

            if let model, !model.isEmpty {
                arguments.append(contentsOf: ["--model", model])
            }

            process.arguments = arguments
            configureProcessEnvironment(process)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = stdinPipe
            try? stdinPipe.fileHandleForWriting.close()

            activeProcesses[conversationId] = process

            let parser = StreamJSONParser()
            var streamedText = ""
            var extractedSessionId: String?
            var finalResponse: ClaudeResponse?
            var streamErrorMessage: String?
            var didFinish = false

            func finish(_ result: Result<ClaudeResponse, Error>) {
                guard !didFinish else { return }
                didFinish = true
                stdoutPipe.fileHandleForReading.readabilityHandler = nil

                switch result {
                case .success(let response):
                    continuation.resume(returning: response)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            func applyUpdates(_ updates: [StreamJSONUpdate]) {
                for update in updates {
                    if let sessionId = update.sessionId {
                        extractedSessionId = sessionId
                    }

                    if let delta = update.textDelta {
                        streamedText += delta
                        if let onStreamUpdate {
                            Task { @MainActor in onStreamUpdate(delta) }
                        }
                    } else if let fullText = update.fullText {
                        if fullText.count > streamedText.count {
                            let suffix = String(fullText.dropFirst(streamedText.count))
                            if !suffix.isEmpty {
                                streamedText = fullText
                                if let onStreamUpdate {
                                    Task { @MainActor in onStreamUpdate(suffix) }
                                }
                            }
                        } else if streamedText.isEmpty {
                            streamedText = fullText
                            if let onStreamUpdate {
                                Task { @MainActor in onStreamUpdate(fullText) }
                            }
                        }
                    }

                    if let response = update.finalResponse {
                        finalResponse = response
                    }

                    if let errorMessage = update.errorMessage {
                        streamErrorMessage = errorMessage
                    }
                }
            }

            let stdoutHandle = stdoutPipe.fileHandleForReading
            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let updates = parser.append(data)
                guard !updates.isEmpty else { return }

                Task { @MainActor in
                    applyUpdates(updates)
                }
            }

            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if process.isRunning {
                    timedOutConversationIds.insert(conversationId)
                    process.terminate()
                }
            }

            process.terminationHandler = { [weak self] proc in
                timeoutTask.cancel()
                stdoutHandle.readabilityHandler = nil

                let trailingStdout = stdoutHandle.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                let trailingUpdates = parser.append(trailingStdout) + parser.flush()

                Task { @MainActor in
                    self?.activeProcesses.removeValue(forKey: conversationId)

                    applyUpdates(trailingUpdates)

                    let wasCancelled = self?.cancelledConversationIds.remove(conversationId) != nil
                    let wasTimeout = self?.timedOutConversationIds.remove(conversationId) != nil

                    if Task.isCancelled || wasCancelled {
                        finish(.failure(ClaudeProcessError.cancelled))
                        return
                    }

                    if wasTimeout {
                        finish(.failure(ClaudeProcessError.timeout))
                        return
                    }

                    if let streamErrorMessage {
                        finish(.failure(ClaudeProcessError.processFailed(
                            exitCode: 1,
                            stderr: streamErrorMessage
                        )))
                        return
                    }

                    guard proc.terminationStatus == 0 else {
                        if stderr.contains("not logged in") || stderr.contains("login") {
                            finish(.failure(ClaudeProcessError.cliNotFound))
                            return
                        }
                        finish(.failure(ClaudeProcessError.processFailed(
                            exitCode: proc.terminationStatus,
                            stderr: stderr.isEmpty ? streamedText : stderr
                        )))
                        return
                    }

                    if let finalResponse {
                        if finalResponse.isError {
                            finish(.failure(ClaudeProcessError.processFailed(
                                exitCode: 1,
                                stderr: finalResponse.result ?? "Unknown error"
                            )))
                        } else {
                            let resolved = ClaudeResponse(
                                result: finalResponse.result ?? streamedText,
                                session_id: finalResponse.session_id ?? extractedSessionId,
                                total_cost_usd: finalResponse.total_cost_usd,
                                duration_ms: finalResponse.duration_ms,
                                is_error: finalResponse.is_error
                            )
                            finish(.success(resolved))
                        }
                        return
                    }

                    if !streamedText.isEmpty || extractedSessionId != nil {
                        finish(.success(ClaudeResponse(
                            result: streamedText,
                            session_id: extractedSessionId,
                            total_cost_usd: nil,
                            duration_ms: nil,
                            is_error: false
                        )))
                        return
                    }

                    finish(.failure(ClaudeProcessError.parseFailed(
                        stderr.isEmpty ? "No stream-json response received" : stderr
                    )))
                }
            }

            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                stdoutHandle.readabilityHandler = nil
                activeProcesses.removeValue(forKey: conversationId)
                finish(.failure(ClaudeProcessError.processFailed(
                    exitCode: -1,
                    stderr: error.localizedDescription
                )))
            }
        }
    }

    private func configureProcessEnvironment(_ process: Process) {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSHomeDirectory()
        environment["USER"] = NSUserName()
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
    }
}

private extension Data {
    var nonEmpty: Data? {
        isEmpty ? nil : self
    }
}
