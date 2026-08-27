import Foundation

enum ClaudeCLIError: LocalizedError {
    case notFound
    case resolutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Claude CLI nicht gefunden. Bitte installiere Claude Code und führe `claude login` im Terminal aus."
        case .resolutionFailed(let detail):
            return "Claude CLI konnte nicht aufgelöst werden: \(detail)"
        }
    }
}

enum ClaudeCLIResolver {
    private static let cachedPathKey = "claudeCLIPath"
    private static let manualOverrideKey = "claudeCLIPathOverride"

    static func resolvedPath() async throws -> String {
        if let override = UserDefaults.standard.string(forKey: manualOverrideKey),
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        if let cached = UserDefaults.standard.string(forKey: cachedPathKey),
           !cached.isEmpty,
           FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }

        let path = try await resolveViaLoginShell()
        UserDefaults.standard.set(path, forKey: cachedPathKey)
        return path
    }

    static func invalidateCache() {
        UserDefaults.standard.removeObject(forKey: cachedPathKey)
    }

    private static func resolveViaLoginShell() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "which claude"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus == 0, !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) {
                    continuation.resume(returning: output)
                } else if output.isEmpty {
                    continuation.resume(throwing: ClaudeCLIError.notFound)
                } else {
                    continuation.resume(throwing: ClaudeCLIError.resolutionFailed("Exit-Code \(proc.terminationStatus)"))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ClaudeCLIError.resolutionFailed(error.localizedDescription))
            }
        }
    }
}
