import Foundation

private let hostDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claudechat", isDirectory: true)

private var socketPath: String {
    hostDirectory.appendingPathComponent("claudechat.sock").path
}

// MARK: - Native Messaging (Firefox length-prefixed JSON on stdin/stdout)

private func readNativeMessage() -> Data? {
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    guard readFully(STDIN_FILENO, &lengthBytes, 4) else { return nil }

    let length = Int(lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
    guard length > 0, length <= 10_000_000 else { return nil }

    var data = Data(count: length)
    let success = data.withUnsafeMutableBytes { buffer -> Bool in
        guard let base = buffer.baseAddress else { return false }
        return readFully(STDIN_FILENO, base, length)
    }
    return success ? data : nil
}

private func writeNativeMessage(_ data: Data) {
    var length = UInt32(data.count).littleEndian
    withUnsafeBytes(of: &length) { writeFully(STDOUT_FILENO, $0.baseAddress!, 4) }
    data.withUnsafeBytes { writeFully(STDOUT_FILENO, $0.baseAddress!, data.count) }
}

private func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Bool {
    var total = 0
    while total < count {
        let n = read(fd, buffer.advanced(by: total), count - total)
        if n <= 0 { return false }
        total += n
    }
    return true
}

private func writeFully(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) {
    var total = 0
    while total < count {
        let n = write(fd, buffer.advanced(by: total), count - total)
        if n <= 0 { break }
        total += n
    }
}

private func copyPath(_ path: String, into addr: inout sockaddr_un) {
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    path.withCString { cString in
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            let bound = rawBuffer.bindMemory(to: CChar.self)
            strncpy(bound.baseAddress, cString, capacity - 1)
        }
    }
}

// MARK: - Unix Domain Socket (App ↔ Host)

private let pendingLock = NSLock()
private var pendingSocketResponses: [(Data) -> Void] = []
private var socketServerFD: Int32 = -1

private func encodeSocketResponse(ok: Bool, title: String? = nil, url: String? = nil, text: String? = nil, error: String? = nil) -> Data {
    var payload: [String: Any] = ["ok": ok]
    if let title { payload["title"] = title }
    if let url { payload["url"] = url }
    if let text { payload["text"] = text }
    if let error { payload["error"] = error }
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"ok\":false,\"error\":\"Encoding fehlgeschlagen\"}".utf8)
    return data + Data([0x0A])
}

private func fulfillPendingSocketResponse(_ response: Data) {
    pendingLock.lock()
    defer { pendingLock.unlock() }
    guard !pendingSocketResponses.isEmpty else { return }
    let handler = pendingSocketResponses.removeFirst()
    handler(response)
}

private func unixSocketAddressLength(path: String) -> socklen_t {
    socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + path.utf8.count + 1)
}

private func handleExtensionMessage(_ data: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fulfillPendingSocketResponse(encodeSocketResponse(ok: false, error: "Ungültige Extension-Antwort"))
        return
    }

    if let action = json["action"] as? String, action == "ping" {
        return
    }

    if let error = json["error"] as? String {
        fulfillPendingSocketResponse(encodeSocketResponse(ok: false, error: error))
        return
    }

    let title = json["title"] as? String ?? ""
    let url = json["url"] as? String ?? ""
    let text = json["text"] as? String ?? ""
    fulfillPendingSocketResponse(encodeSocketResponse(ok: true, title: title, url: url, text: text))
}

private func startSocketServer() {
    let path = socketPath
    unlink(path)

    socketServerFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketServerFD >= 0 else { return }

    var addr = sockaddr_un()
    copyPath(path, into: &addr)

    let addrLen = unixSocketAddressLength(path: path)
    let bindResult = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(socketServerFD, sockaddrPointer, addrLen)
        }
    }
    guard bindResult == 0 else {
        close(socketServerFD)
        socketServerFD = -1
        return
    }

    listen(socketServerFD, 5)

    DispatchQueue.global(qos: .userInitiated).async {
        while socketServerFD >= 0 {
            let clientFD = accept(socketServerFD, nil, nil)
            guard clientFD >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async {
                handleSocketClient(clientFD)
            }
        }
    }
}

private func handleSocketClient(_ clientFD: Int32) {
    defer { close(clientFD) }

    var buffer = Data()
    var byte: UInt8 = 0

    while read(clientFD, &byte, 1) == 1 {
        if byte == 0x0A { break }
        buffer.append(byte)
    }

    guard !buffer.isEmpty else { return }

    let semaphore = DispatchSemaphore(value: 0)
    var responseData = encodeSocketResponse(ok: false, error: "Zeitüberschreitung")

    pendingLock.lock()
    pendingSocketResponses.append { response in
        responseData = response
        semaphore.signal()
    }
    pendingLock.unlock()

    guard
        let request = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
        let action = request["action"] as? String,
        action == "extract"
    else {
        pendingLock.lock()
        if !pendingSocketResponses.isEmpty {
            pendingSocketResponses.removeLast()
        }
        pendingLock.unlock()
        responseData = encodeSocketResponse(ok: false, error: "Unbekannte Anfrage")
        responseData.withUnsafeBytes { bytes in
            _ = write(clientFD, bytes.baseAddress, responseData.count)
        }
        return
    }

    let extractRequest = Data("{\"action\":\"extract\"}".utf8)
    writeNativeMessage(extractRequest)

    let waitResult = semaphore.wait(timeout: .now() + 15)
    if waitResult == .timedOut {
        pendingLock.lock()
        if !pendingSocketResponses.isEmpty {
            pendingSocketResponses.removeLast()
        }
        pendingLock.unlock()
        responseData = encodeSocketResponse(ok: false, error: "Extension hat nicht rechtzeitig geantwortet")
    }

    responseData.withUnsafeBytes { bytes in
        _ = write(clientFD, bytes.baseAddress, responseData.count)
    }
}

private func cleanup() {
    if socketServerFD >= 0 {
        close(socketServerFD)
        socketServerFD = -1
    }
    unlink(socketPath)
}

// MARK: - Entry

try? FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)

startSocketServer()

while let message = readNativeMessage() {
    handleExtensionMessage(message)
}

cleanup()
exit(0)
