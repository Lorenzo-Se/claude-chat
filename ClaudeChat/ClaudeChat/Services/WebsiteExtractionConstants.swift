import Foundation

enum WebsiteExtractionConstants {
    static let bundleID = "dev.claudechat"
    static let nativeHostName = "dev.claudechat"
    static let extensionID = "claudechat@dev.local"
    /// Firefox Native Messaging: `allowed_extensions` (nicht Chrome `allowed_origins`).
    static let allowedExtensions = [extensionID]

    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    /// Ohne Leerzeichen im Pfad – Firefox startet Native-Messaging-Hosts sonst oft nicht.
    static var nativeHostDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudechat", isDirectory: true)
    }

    static var nativeHostBinaryURL: URL {
        nativeHostDirectory.appendingPathComponent("ClaudeChatNativeHost")
    }

    static var socketPath: String {
        nativeHostDirectory.appendingPathComponent("claudechat.sock").path
    }

    static var mozillaNativeMessagingHostsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts", isDirectory: true)
    }

    static var nativeHostManifestURL: URL {
        mozillaNativeMessagingHostsDirectory.appendingPathComponent("\(nativeHostName).json")
    }

    /// Zen Browser nutzt dieselbe Mozilla Native-Messaging-Pfadstruktur.
    static var zenNativeMessagingHostsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zen/NativeMessagingHosts", isDirectory: true)
    }

    static var zenNativeHostManifestURL: URL {
        zenNativeMessagingHostsDirectory.appendingPathComponent("\(nativeHostName).json")
    }
}
