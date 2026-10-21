// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeChat",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeChat", targets: ["ClaudeChat"]),
        .executable(name: "ClaudeChatNativeHost", targets: ["ClaudeChatNativeHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", exact: "0.2.1"),
    ],
    targets: [
        // Pure logic (CLI protocol, persistence, templates, Markdown, speech text). No AppKit.
        .target(name: "ClaudeChatCore"),
        .executableTarget(
            name: "ClaudeChat",
            dependencies: ["ClaudeChatCore", "HotKey"]
        ),
        .executableTarget(name: "ClaudeChatNativeHost"),
        .testTarget(name: "ClaudeChatCoreTests", dependencies: ["ClaudeChatCore"]),
    ]
)
