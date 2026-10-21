import AppKit
import HotKey

enum HotkeyAction: String, CaseIterable, Identifiable {
    case toggleChat
    case fullscreenCapture
    case regionCapture
    case websiteExtract
    case sendActiveFile
    case newConversation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleChat: "Toggle chat"
        case .fullscreenCapture: "Full-screen screenshot"
        case .regionCapture: "Region screenshot"
        case .websiteExtract: "Extract website"
        case .sendActiveFile: "Send file"
        case .newConversation: "New conversation"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .toggleChat: Shortcut(key: .k, modifiers: [.control, .option, .command])
        case .fullscreenCapture: Shortcut(key: .s, modifiers: [.option, .shift])
        case .regionCapture: Shortcut(key: .d, modifiers: [.option, .shift])
        case .websiteExtract: Shortcut(key: .w, modifiers: [.option, .shift])
        case .sendActiveFile: Shortcut(key: .f, modifiers: [.option, .shift])
        case .newConversation: Shortcut(key: .n, modifiers: [.option, .shift])
        }
    }
}

/// Stored as JSON in UserDefaults; field names match earlier app versions.
struct Shortcut: Codable, Equatable, Hashable {
    var carbonKeyCode: UInt32
    var modifierRawValue: UInt

    init(key: Key, modifiers: NSEvent.ModifierFlags) {
        carbonKeyCode = key.carbonKeyCode
        modifierRawValue = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var key: Key? { Key(carbonKeyCode: carbonKeyCode) }
    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRawValue).intersection(Self.relevantModifiers) }

    var displayLabel: String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        return label + (key.map(Self.keyName) ?? "?")
    }

    private static func keyName(_ key: Key) -> String {
        let name = String(describing: key)
        if name.count == 1 { return name.uppercased() }
        switch key {
        case .return: return "↩"
        case .escape: return "⎋"
        case .delete: return "⌫"
        case .tab: return "⇥"
        case .space: return "Space"
        default: return name.capitalized
        }
    }
}

/// Registers the global (Carbon) hotkeys. HotKey delivers key-down on the main thread.
@MainActor
final class HotkeyManager {
    private var registered: [HotkeyAction: HotKey] = [:]
    private let handler: (HotkeyAction) -> Void

    init(handler: @escaping (HotkeyAction) -> Void) {
        self.handler = handler
    }

    func register(_ shortcuts: [HotkeyAction: Shortcut]) {
        registered.removeAll()
        for action in HotkeyAction.allCases {
            guard let shortcut = shortcuts[action], let key = shortcut.key else { continue }
            let hotKey = HotKey(key: key, modifiers: shortcut.modifiers)
            hotKey.keyDownHandler = { [weak self] in
                MainActor.assumeIsolated { self?.handler(action) }
            }
            registered[action] = hotKey
        }
    }

    /// While a shortcut is being recorded, the global hotkeys must not swallow the key press.
    func unregisterAll() {
        registered.removeAll()
    }
}
