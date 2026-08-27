import Foundation

struct WebsiteContent: Equatable {
    let title: String
    let url: String
    let text: String
}

enum WebsiteContentServiceError: LocalizedError {
    case hostNotInstalled
    case socketConnectionFailed
    case requestFailed(String)
    case invalidResponse
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .hostNotInstalled:
            return "Native Messaging host is not installed. Please restart Claude Chat."
        case .socketConnectionFailed:
            return "No connection to the browser. Firefox/Zen must be running and the Claude Chat extension must be active."
        case .requestFailed(let message):
            return message
        case .invalidResponse:
            return "Invalid response from the browser."
        case .emptyContent:
            return "No readable content found on the active page."
        }
    }
}

enum WebsiteContentService {
    private static let requestTimeout: TimeInterval = 15
    private static let socketConnectAttempts = 10
    private static let socketConnectRetryDelay: TimeInterval = 0.3

    private static func copyPath(_ path: String, into addr: inout sockaddr_un) {
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { cString in
            withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
                let bound = rawBuffer.bindMemory(to: CChar.self)
                strncpy(bound.baseAddress, cString, capacity - 1)
            }
        }
    }

    static func extractFromActiveTab() async throws -> WebsiteContent {
        guard NativeMessagingHostInstaller.isInstalled() else {
            throw WebsiteContentServiceError.hostNotInstalled
        }

        let request = Data("{\"action\":\"extract\"}\n".utf8)
        let responseData = try await sendSocketRequest(request)
        return try parseResponse(responseData)
    }

    private static func unixSocketAddressLength(path: String) -> socklen_t {
        socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + path.utf8.count + 1)
    }

    private static func openSocketConnection(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        copyPath(path, into: &addr)
        let addrLen = unixSocketAddressLength(path: path)

        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, addrLen)
            }
        }

        guard connectResult == 0 else {
            close(fd)
            return nil
        }

        return fd
    }

    private static func sendSocketRequest(_ request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let path = WebsiteExtractionConstants.socketPath
                var fd: Int32 = -1

                for attempt in 0..<socketConnectAttempts {
                    if let connected = openSocketConnection(path: path) {
                        fd = connected
                        break
                    }
                    if attempt < socketConnectAttempts - 1 {
                        Thread.sleep(forTimeInterval: socketConnectRetryDelay)
                    }
                }

                guard fd >= 0 else {
                    continuation.resume(throwing: WebsiteContentServiceError.socketConnectionFailed)
                    return
                }
                defer { close(fd) }

                var requestWithNewline = request
                if requestWithNewline.last != 0x0A {
                    requestWithNewline.append(0x0A)
                }

                requestWithNewline.withUnsafeBytes { bytes in
                    _ = write(fd, bytes.baseAddress, requestWithNewline.count)
                }

                var received = Data()
                var byte: UInt8 = 0
                let deadline = Date().addingTimeInterval(requestTimeout)

                while Date() < deadline {
                    let n = read(fd, &byte, 1)
                    if n == 1 {
                        if byte == 0x0A { break }
                        received.append(byte)
                    } else if n == 0 {
                        break
                    }
                }

                guard !received.isEmpty else {
                    continuation.resume(throwing: WebsiteContentServiceError.socketConnectionFailed)
                    return
                }

                continuation.resume(returning: received)
            }
        }
    }

    private static func parseResponse(_ data: Data) throws -> WebsiteContent {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebsiteContentServiceError.invalidResponse
        }

        let ok = json["ok"] as? Bool ?? false
        if !ok {
            let error = json["error"] as? String ?? "Unknown error"
            throw WebsiteContentServiceError.requestFailed(error)
        }

        let title = (json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = (json["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw WebsiteContentServiceError.emptyContent
        }

        return WebsiteContent(title: title, url: url, text: text)
    }

    static func applyTemplate(_ template: String, content: WebsiteContent) -> String {
        template
            .replacingOccurrences(of: "{url}", with: content.url)
            .replacingOccurrences(of: "{title}", with: content.title)
            .replacingOccurrences(of: "{content}", with: content.text)
    }

    static func applyScreenshotTemplate(_ template: String, path: String, userText: String = "") -> String {
        template
            .replacingOccurrences(of: "{path}", with: path)
            .replacingOccurrences(of: "{userText}", with: userText)
    }

    static func resolveSystemPrompt(
        for content: WebsiteContent,
        defaultPrompt: String,
        overrides: [WebsiteURLPromptOverride]
    ) -> String {
        for override in overrides {
            if urlMatches(pattern: override.pattern, url: content.url) {
                return override.prompt
            }
        }
        return defaultPrompt
    }

    static func urlMatches(pattern: String, url: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }

        let urlLower = url.lowercased()

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return urlLower.hasPrefix(trimmed)
        }

        if trimmed.contains("/") {
            return urlLower.contains(trimmed)
        }

        guard let parsed = URL(string: url), let host = parsed.host?.lowercased() else {
            return urlLower.contains(trimmed)
        }

        return host == trimmed || host.hasSuffix("." + trimmed)
    }

    static func buildRawContent(for content: WebsiteContent) -> String {
        var parts: [String] = []
        if !content.url.isEmpty {
            parts.append("URL: \(content.url)")
        }
        if !content.title.isEmpty {
            parts.append("Title: \(content.title)")
        }
        if !parts.isEmpty {
            parts.append("")
        }
        parts.append(content.text)
        return parts.joined(separator: "\n")
    }

    static func buildPrompt(for content: WebsiteContent, userPrompt: String = "") -> String {
        var parts: [String] = []

        if !userPrompt.isEmpty {
            parts.append(userPrompt)
            parts.append("")
        }

        parts.append("Analyze this website:")
        if !content.url.isEmpty {
            parts.append("URL: \(content.url)")
        }
        if !content.title.isEmpty {
            parts.append("Title: \(content.title)")
        }
        parts.append("Content:")
        parts.append(content.text)

        return parts.joined(separator: "\n")
    }
}
