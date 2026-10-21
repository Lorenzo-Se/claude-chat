// Native Messaging host for the Firefox/Zen extension.
// Browser ↔ host: length-prefixed JSON on stdin/stdout. App ↔ host: one JSON line per request on a Unix socket.
// Requests are handled one at a time; a reply that arrives after its request timed out is discarded
// so it can never be delivered to the next request.

import Foundation

let hostDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudechat", isDirectory: true)
let socketPath = hostDirectory.appendingPathComponent("claudechat.sock").path
let extensionTimeout: DispatchTimeInterval = .seconds(15)

signal(SIGPIPE, SIG_IGN)

// MARK: - Browser side (stdin/stdout)

let stdoutLock = NSLock()

func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Bool {
    var total = 0
    while total < count {
        let n = read(fd, buffer.advanced(by: total), count - total)
        if n < 0, errno == EINTR { continue }
        if n <= 0 { return false }
        total += n
    }
    return true
}

func writeFully(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        guard var pointer = raw.baseAddress else { return }
        var remaining = raw.count
        while remaining > 0 {
            let n = write(fd, pointer, remaining)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return }
            pointer = pointer.advanced(by: n)
            remaining -= n
        }
    }
}

func readNativeMessage() -> Data? {
    var length: UInt32 = 0
    guard readFully(STDIN_FILENO, &length, 4) else { return nil }
    let count = Int(UInt32(littleEndian: length))
    guard count > 0, count <= 64 * 1024 * 1024 else { return nil }
    var data = Data(count: count)
    let ok = data.withUnsafeMutableBytes { readFully(STDIN_FILENO, $0.baseAddress!, count) }
    return ok ? data : nil
}

func writeNativeMessage(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    var length = UInt32(data.count).littleEndian
    stdoutLock.lock()
    defer { stdoutLock.unlock() }
    writeFully(STDOUT_FILENO, Data(bytes: &length, count: 4))
    writeFully(STDOUT_FILENO, data)
}

// MARK: - Request/response pairing

final class PendingRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Data) -> Void)?
    private var staleReplies = 0
    private var abandonedAt = Date.distantPast

    func begin(_ handler: @escaping (Data) -> Void) {
        lock.lock(); defer { lock.unlock() }
        // Late replies arrive within seconds; after that the extension never answered, so stop waiting for it.
        if staleReplies > 0, Date().timeIntervalSince(abandonedAt) > 10 {
            staleReplies = 0
        }
        self.handler = handler
    }

    /// Called on timeout. If no reply came, the eventual late reply must be dropped.
    func abandon() {
        lock.lock(); defer { lock.unlock() }
        if handler != nil {
            handler = nil
            staleReplies += 1
            abandonedAt = Date()
        }
    }

    func deliver(_ response: Data) {
        lock.lock()
        if staleReplies > 0 {
            staleReplies -= 1
            lock.unlock()
            return
        }
        let current = handler
        handler = nil
        lock.unlock()
        current?(response)
    }
}

let pending = PendingRequest()

func socketResponse(_ payload: [String: Any]) -> Data {
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(#"{"ok":false,"error":"Encoding failed"}"#.utf8)
    return data + Data([0x0A])
}

func handleExtensionMessage(_ data: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        pending.deliver(socketResponse(["ok": false, "error": "Invalid extension response"]))
        return
    }
    if json["action"] as? String == "ping" { return }

    if let error = json["error"] as? String {
        pending.deliver(socketResponse(["ok": false, "error": error]))
        return
    }
    pending.deliver(socketResponse([
        "ok": true,
        "title": json["title"] as? String ?? "",
        "url": json["url"] as? String ?? "",
        "text": json["text"] as? String ?? "",
    ]))
}

// MARK: - App side (Unix socket)

let requestQueue = DispatchQueue(label: "dev.claudechat.nativehost.requests")

func withSocketAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    _ = withUnsafeMutableBytes(of: &address.sun_path) { raw in
        socketPath.withCString { strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, capacity - 1) }
    }
    let length = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + min(socketPath.utf8.count, capacity - 1) + 1)
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
    }
}

func readLine(from fd: Int32) -> Data? {
    var line = Data()
    var byte: UInt8 = 0
    while line.count < 64 * 1024 {
        let n = read(fd, &byte, 1)
        if n < 0, errno == EINTR { continue }
        if n <= 0 { return nil }
        if byte == 0x0A { return line }
        line.append(byte)
    }
    return nil
}

func handleClient(_ fd: Int32) {
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    guard let line = readLine(from: fd),
          let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          request["action"] as? String == "extract" else {
        writeFully(fd, socketResponse(["ok": false, "error": "Unknown request"]))
        return
    }

    let semaphore = DispatchSemaphore(value: 0)
    let responseLock = NSLock()
    var response = socketResponse(["ok": false, "error": "Extension did not respond in time"])
    pending.begin { data in
        responseLock.lock()
        response = data
        responseLock.unlock()
        semaphore.signal()
    }
    writeNativeMessage(["action": "extract"])

    if semaphore.wait(timeout: .now() + extensionTimeout) == .timedOut {
        pending.abandon()
    }
    responseLock.lock()
    let reply = response
    responseLock.unlock()
    writeFully(fd, reply)
}

/// Returns the inode of the bound socket file (0 if the server could not start).
func startSocketServer() -> ino_t {
    try? FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
    unlink(socketPath)

    let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard serverFD >= 0 else { return 0 }
    guard withSocketAddress({ bind(serverFD, $0, $1) }) == 0, listen(serverFD, 8) == 0 else {
        close(serverFD)
        return 0
    }
    chmod(socketPath, 0o600)
    var info = stat()
    let inode = stat(socketPath, &info) == 0 ? info.st_ino : 0

    Thread.detachNewThread {
        while true {
            let client = accept(serverFD, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            requestQueue.async { handleClient(client) }
        }
    }
    return inode
}

/// Another host instance (second browser) may have re-bound the path; only remove our own socket.
func removeOwnSocket(inode: ino_t) {
    var info = stat()
    if inode != 0, stat(socketPath, &info) == 0, info.st_ino == inode {
        unlink(socketPath)
    }
}

// MARK: - Entry

let socketInode = startSocketServer()
while let message = readNativeMessage() {
    handleExtensionMessage(message)
}
removeOwnSocket(inode: socketInode)
exit(0)
