import ClaudeChatCore
import Foundation

enum WebsiteExtractionError: LocalizedError {
    case browserNotConnected
    case failed(String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .browserNotConnected:
            "No connection to the browser. Firefox or Zen must be running with the Claude Chat extension enabled."
        case .failed(let message):
            message
        case .emptyContent:
            "No readable content found on the active page."
        }
    }
}

/// Asks the Native Messaging host (started by Firefox/Zen) for the active tab's content via its Unix socket.
enum WebsiteExtractor {
    static func extractActiveTab() async throws -> WebsiteContent {
        let data = try await Task.detached(priority: .userInitiated) {
            try request(Data(#"{"action":"extract"}"#.utf8) + Data([0x0A]))
        }.value

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebsiteExtractionError.failed("Invalid response from the browser.")
        }
        guard json["ok"] as? Bool == true else {
            throw WebsiteExtractionError.failed(json["error"] as? String ?? "Unknown error from the browser.")
        }
        let content = WebsiteContent(
            title: (json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            url: (json["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            text: (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !content.text.isEmpty else { throw WebsiteExtractionError.emptyContent }
        return content
    }

    /// Blocking socket round-trip; runs off the main thread.
    private static func request(_ payload: Data) throws -> Data {
        let fd = try connectWithRetry()
        defer { close(fd) }

        // The host waits up to 15 s for the extension; allow a little more.
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }
        guard written == payload.count else { throw WebsiteExtractionError.browserNotConnected }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count < 0 { throw WebsiteExtractionError.failed("The browser did not respond in time.") }
            if count == 0 { break }
            response.append(buffer, count: count)
            if let newline = response.firstIndex(of: 0x0A) {
                return response[..<newline]
            }
        }
        guard !response.isEmpty else { throw WebsiteExtractionError.browserNotConnected }
        return response
    }

    /// The host may still be starting right after the browser launched.
    private static func connectWithRetry(attempts: Int = 5) throws -> Int32 {
        let path = AppPaths.nativeHostSocket
        for attempt in 0..<attempts {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { break }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            _ = withUnsafeMutableBytes(of: &address.sun_path) { raw in
                path.withCString { strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, capacity - 1) }
            }
            let length = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + min(path.utf8.count, capacity - 1) + 1)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
            }
            if result == 0 { return fd }
            close(fd)
            if attempt < attempts - 1 { Thread.sleep(forTimeInterval: 0.3) }
        }
        throw WebsiteExtractionError.browserNotConnected
    }
}

/// Copies the bundled host to ~/.claudechat and registers it with Firefox/Zen. Idempotent; only writes on change.
enum NativeHostInstaller {
    static func installInBackground() {
        Task.detached(priority: .utility) {
            do {
                try install()
            } catch {
                NSLog("Claude Chat: Native Messaging host installation failed: \(error.localizedDescription)")
            }
        }
    }

    private static func install() throws {
        let fileManager = FileManager.default
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "ClaudeChatNativeHost") else {
            NSLog("Claude Chat: Native Messaging host not found in the app bundle (development run?).")
            return
        }
        try fileManager.createDirectory(at: AppPaths.nativeHostDirectory, withIntermediateDirectories: true)

        let destination = AppPaths.nativeHostBinary
        let bundledData = try Data(contentsOf: bundled)
        if (try? Data(contentsOf: destination)) != bundledData {
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: bundled, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            // A downloaded app carries quarantine; Firefox could not launch the copied host then.
            removexattr(destination.path, "com.apple.quarantine", 0)
        }

        let manifest: [String: Any] = [
            "name": AppPaths.nativeHostName,
            "description": "Claude Chat Native Messaging Host",
            "path": destination.path,
            "type": "stdio",
            "allowed_extensions": [AppPaths.extensionID],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])

        for (offset, directory) in AppPaths.nativeMessagingManifestDirectories.enumerated() {
            // Mozilla always; other browsers only when installed (their support folder exists).
            let browserFolder = directory.deletingLastPathComponent()
            guard offset == 0 || fileManager.fileExists(atPath: browserFolder.path) else { continue }
            let file = directory.appendingPathComponent("\(AppPaths.nativeHostName).json")
            if (try? Data(contentsOf: file)) == manifestData { continue }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manifestData.write(to: file, options: .atomic)
        }
    }
}
