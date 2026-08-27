import Foundation

enum NativeMessagingHostInstallerError: LocalizedError {
    case bundledHostMissing
    case copyFailed
    case manifestWriteFailed

    var errorDescription: String? {
        switch self {
        case .bundledHostMissing:
            return "Native Messaging host was not found in the app bundle."
        case .copyFailed:
            return "Native Messaging host could not be installed."
        case .manifestWriteFailed:
            return "Native Messaging manifest could not be registered."
        }
    }
}

enum NativeMessagingHostInstaller {
    private static let fileManager = FileManager.default

    /// Installs host binary and manifests on app launch (idempotent).
    static func installIfNeeded() {
        do {
            try install()
        } catch {
            NSLog("Native Messaging host installation failed: \(error.localizedDescription)")
        }
    }

    static func install() throws {
        try fileManager.createDirectory(
            at: WebsiteExtractionConstants.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: WebsiteExtractionConstants.nativeHostDirectory,
            withIntermediateDirectories: true
        )

        try copyHostBinaryIfNeeded()
        try signHostBinaryIfNeeded()
        try writeManifests()
    }

    static func isInstalled() -> Bool {
        let binaryPath = WebsiteExtractionConstants.nativeHostBinaryURL.path
        let manifestPath = WebsiteExtractionConstants.nativeHostManifestURL.path
        return fileManager.isExecutableFile(atPath: binaryPath)
            && fileManager.fileExists(atPath: manifestPath)
    }

    private static func copyHostBinaryIfNeeded() throws {
        guard let bundledHost = Bundle.main.url(forResource: "ClaudeChatNativeHost", withExtension: nil) else {
            throw NativeMessagingHostInstallerError.bundledHostMissing
        }

        let destination = WebsiteExtractionConstants.nativeHostBinaryURL

        if fileManager.fileExists(atPath: destination.path) {
            if let bundledData = try? Data(contentsOf: bundledHost),
               let installedData = try? Data(contentsOf: destination),
               bundledData == installedData {
                return
            }
            try? fileManager.removeItem(at: destination)
        }

        try fileManager.copyItem(at: bundledHost, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    private static func signHostBinaryIfNeeded() throws {
        let binaryURL = WebsiteExtractionConstants.nativeHostBinaryURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", binaryURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NativeMessagingHostInstallerError.copyFailed
        }
    }

    private static func writeManifests() throws {
        let manifest = makeManifest(hostPath: WebsiteExtractionConstants.nativeHostBinaryURL.path)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])

        try writeManifest(data, to: WebsiteExtractionConstants.mozillaNativeMessagingHostsDirectory,
                          fileURL: WebsiteExtractionConstants.nativeHostManifestURL)

        if fileManager.fileExists(atPath: WebsiteExtractionConstants.zenNativeMessagingHostsDirectory.path)
            || fileManager.fileExists(atPath: "/Applications/Zen Browser.app")
            || fileManager.fileExists(atPath: "/Applications/Zen.app") {
            try writeManifest(data, to: WebsiteExtractionConstants.zenNativeMessagingHostsDirectory,
                              fileURL: WebsiteExtractionConstants.zenNativeHostManifestURL)
        }
    }

    private static func makeManifest(hostPath: String) -> [String: Any] {
        [
            "name": WebsiteExtractionConstants.nativeHostName,
            "description": "Claude Chat Native Messaging Host",
            "path": hostPath,
            "type": "stdio",
            "allowed_extensions": WebsiteExtractionConstants.allowedExtensions,
        ]
    }

    private static func writeManifest(_ data: Data, to directory: URL, fileURL: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw NativeMessagingHostInstallerError.manifestWriteFailed
        }
    }
}
