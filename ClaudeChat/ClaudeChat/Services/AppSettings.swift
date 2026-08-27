import AppKit
import Combine
import Foundation
import HotKey

enum HotkeyAction: String, CaseIterable, Identifiable {
    case toggleChat
    case fullscreenCapture
    case regionCapture
    case websiteExtract
    case newConversation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleChat: return "Chat ein-/ausblenden"
        case .fullscreenCapture: return "Vollbild-Screenshot"
        case .regionCapture: return "Bereichs-Screenshot"
        case .websiteExtract: return "Website extrahieren"
        case .newConversation: return "Neue Konversation"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .toggleChat:
            return KeyCombo(key: .k, modifiers: [.control, .option, .command])
        case .fullscreenCapture:
            return KeyCombo(key: .s, modifiers: [.option, .shift])
        case .regionCapture:
            return KeyCombo(key: .d, modifiers: [.option, .shift])
        case .websiteExtract:
            return KeyCombo(key: .w, modifiers: [.option, .shift])
        case .newConversation:
            return KeyCombo(key: .n, modifiers: [.option, .shift])
        }
    }
}

enum ClaudeModelChoice: String, CaseIterable, Identifiable {
    case `default`
    case sonnet
    case opus
    case haiku

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: return "Standard (CLI-Default)"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .haiku: return "Haiku"
        }
    }

    /// CLI-Wert für `--model`; nil = kein Flag setzen.
    var cliValue: String? {
        switch self {
        case .default: return nil
        case .sonnet: return "sonnet"
        case .opus: return "opus"
        case .haiku: return "haiku"
        }
    }
}

extension Notification.Name {
    static let appSettingsDidChange = Notification.Name("appSettingsDidChange")
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let hotkeyPrefix = "hotkey."
        static let cliPathOverride = "claudeCLIPathOverride"
        static let model = "claudeModel"
        static let streamingEnabled = "streamingEnabled"
        static let launchAtLogin = "launchAtLogin"
    }

    @Published private(set) var hotkeys: [HotkeyAction: KeyCombo]
    @Published var cliPathOverride: String {
        didSet {
            let trimmed = cliPathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: Keys.cliPathOverride)
            ClaudeCLIResolver.invalidateCache()
            notifyChange()
        }
    }
    @Published var model: ClaudeModelChoice {
        didSet {
            UserDefaults.standard.set(model.rawValue, forKey: Keys.model)
            notifyChange()
        }
    }
    @Published var streamingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(streamingEnabled, forKey: Keys.streamingEnabled)
            notifyChange()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            notifyChange()
        }
    }

    private init() {
        var loadedHotkeys: [HotkeyAction: KeyCombo] = [:]
        for action in HotkeyAction.allCases {
            let key = Keys.hotkeyPrefix + action.rawValue
            if let data = UserDefaults.standard.data(forKey: key),
               let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
                loadedHotkeys[action] = combo
            } else {
                loadedHotkeys[action] = action.defaultCombo
            }
        }
        hotkeys = loadedHotkeys

        cliPathOverride = UserDefaults.standard.string(forKey: Keys.cliPathOverride) ?? ""

        if let raw = UserDefaults.standard.string(forKey: Keys.model),
           let choice = ClaudeModelChoice(rawValue: raw) {
            model = choice
        } else {
            model = .default
        }

        if UserDefaults.standard.object(forKey: Keys.streamingEnabled) != nil {
            streamingEnabled = UserDefaults.standard.bool(forKey: Keys.streamingEnabled)
        } else {
            streamingEnabled = true
        }

        launchAtLogin = UserDefaults.standard.bool(forKey: Keys.launchAtLogin)
    }

    func combo(for action: HotkeyAction) -> KeyCombo {
        hotkeys[action] ?? action.defaultCombo
    }

    func label(for action: HotkeyAction) -> String {
        combo(for: action).displayLabel
    }

    func setCombo(_ combo: KeyCombo, for action: HotkeyAction) {
        hotkeys[action] = combo
        let key = Keys.hotkeyPrefix + action.rawValue
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: key)
        }
        notifyChange()
    }

    func resetHotkey(_ action: HotkeyAction) {
        setCombo(action.defaultCombo, for: action)
    }

    func resetAllHotkeys() {
        for action in HotkeyAction.allCases {
            resetHotkey(action)
        }
    }

    func syncLaunchAtLoginFromSystem() {
        launchAtLogin = LaunchAtLoginManager.isEnabled
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .appSettingsDidChange, object: self)
    }
}

enum AppShortcuts {
    @MainActor
    static var toggleChatLabel: String {
        AppSettings.shared.label(for: .toggleChat)
    }

    @MainActor
    static func matchesToggleChat(_ event: NSEvent) -> Bool {
        AppSettings.shared.combo(for: .toggleChat).matches(event)
    }
}
