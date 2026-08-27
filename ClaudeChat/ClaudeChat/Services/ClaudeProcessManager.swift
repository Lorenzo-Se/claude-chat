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
            return "Claude CLI nicht gefunden. Bitte `claude login` im Terminal ausführen."
        case .processFailed(let code, let stderr):
            return "Claude-Prozess fehlgeschlagen (Exit \(code)): \(stderr)"
        case .parseFailed(let detail):
            return "Antwort konnte nicht gelesen werden: \(detail)"
        case .timeout:
            return "Zeitüberschreitung nach 120 Sekunden."
        case .cancelled:
            return "Anfrage abgebrochen."
        }
    }
}

@MainActor
final class ClaudeProcessManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var runningConversationIds: Set<UUID> = []

    private var activeProcesses: [UUID: Process] = [:]
    private let timeoutSeconds: TimeInterval = 120

    /// Headless-Settings: keine interaktiven Dialoge, Tools vorab freigegeben.
    /// Kein `--dangerously-skip-permissions` — das zeigt einen Bypass-Dialog, den man ablehnen kann,
    /// während Claude trotzdem weitermacht.
    private static let headlessSettingsJSON = """
    {"permissions":{"defaultMode":"dontAsk","allow":["Bash(*)","Read(*)","Edit(*)","Write(*)","Glob(*)","Grep(*)","WebFetch(*)","WebSearch(*)","Task(*)","NotebookEdit(*)","MultiEdit(*)","TodoWrite(*)","Agent(*)","mcp__*"]}}
    """

    func send(
        prompt: String,
        conversationId: UUID,
        sessionId: String?,
        model: String? = nil
    ) async throws -> ClaudeResponse {
        guard activeProcesses[conversationId] == nil else {
            throw ClaudeProcessError.processFailed(exitCode: -1, stderr: "Bereits ein Request aktiv für diese Konversation.")
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

        return try await withTaskCancellationHandler {
            try await runProcess(
                cliPath: cliPath,
                prompt: prompt,
                conversationId: conversationId,
                sessionId: sessionId,
                model: model
            )
        } onCancel: {
            Task { @MainActor in
                self.terminate(conversationId: conversationId)
            }
        }
    }

    func terminate(conversationId: UUID) {
        activeProcesses[conversationId]?.terminate()
    }

    func terminateAll() {
        for process in activeProcesses.values {
            process.terminate()
        }
    }

    private func runProcess(
        cliPath: String,
        prompt: String,
        conversationId: UUID,
        sessionId: String?,
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

            if let sessionId {
                arguments.append(contentsOf: ["--resume", sessionId])
            }

            if let model, !model.isEmpty {
                arguments.append(contentsOf: ["--model", model])
            }

            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = NSHomeDirectory()
            environment["USER"] = NSUserName()
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

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
                    process.terminate()
                }
            }

            process.terminationHandler = { [weak self] proc in
                timeoutTask.cancel()
                Task { @MainActor in
                    self?.activeProcesses.removeValue(forKey: conversationId)
                }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if Task.isCancelled {
                    continuation.resume(throwing: ClaudeProcessError.cancelled)
                    return
                }

                if proc.terminationStatus == 15 || proc.terminationReason == .uncaughtSignal {
                    if timeoutTask.isCancelled == false && proc.terminationStatus != 0 {
                        // timeout path
                    }
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

                guard let data = stdout.data(using: .utf8) else {
                    continuation.resume(throwing: ClaudeProcessError.parseFailed("Keine UTF-8-Ausgabe"))
                    return
                }

                do {
                    let response = try JSONDecoder().decode(ClaudeResponse.self, from: data)
                    if response.isError {
                        continuation.resume(throwing: ClaudeProcessError.processFailed(
                            exitCode: 1,
                            stderr: response.result ?? "Unbekannter Fehler"
                        ))
                    } else {
                        continuation.resume(returning: response)
                    }
                } catch {
                    continuation.resume(throwing: ClaudeProcessError.parseFailed(error.localizedDescription))
                }
            }

            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                Task { @MainActor in
                    self.activeProcesses.removeValue(forKey: conversationId)
                }
                continuation.resume(throwing: ClaudeProcessError.processFailed(
                    exitCode: -1,
                    stderr: error.localizedDescription
                ))
            }
        }
    }
}
