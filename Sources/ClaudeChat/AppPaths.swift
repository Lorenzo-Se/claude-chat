import ClaudeChatCore
import Foundation

enum AppPaths {
    /// Fixed (not `Bundle.main.bundleIdentifier`) so debug runs from `swift run` share the app's data.
    static let bundleID = "dev.claudechat"

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    static var conversations: URL {
        applicationSupport.appendingPathComponent("conversations", isDirectory: true)
    }

    private static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    static let screenshots = TemporaryFileStore(directory: caches.appendingPathComponent("screenshots", isDirectory: true))
    static let attachments = TemporaryFileStore(directory: caches.appendingPathComponent("attachments", isDirectory: true))

    // Native Messaging. No spaces in the host path — Firefox fails to launch hosts from such paths.
    static let nativeHostName = "dev.claudechat"
    static let extensionID = "claudechat@dev.local"

    static var nativeHostDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudechat", isDirectory: true)
    }

    static var nativeHostBinary: URL {
        nativeHostDirectory.appendingPathComponent("ClaudeChatNativeHost")
    }

    static var nativeHostSocket: String {
        nativeHostDirectory.appendingPathComponent("claudechat.sock").path
    }

    /// Firefox and Zen read host manifests from these directories.
    static var nativeMessagingManifestDirectories: [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return [
            support.appendingPathComponent("Mozilla/NativeMessagingHosts", isDirectory: true),
            support.appendingPathComponent("Zen/NativeMessagingHosts", isDirectory: true),
        ]
    }
}
