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

struct WebsiteURLPromptOverride: Codable, Identifiable, Equatable {
    var id: UUID
    var pattern: String
    var prompt: String

    init(id: UUID = UUID(), pattern: String = "", prompt: String = "") {
        self.id = id
        self.pattern = pattern
        self.prompt = prompt
    }
}

extension Notification.Name {
    static let appSettingsDidChange = Notification.Name("appSettingsDidChange")
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let defaultScreenshotSystemPrompt = "Analysiere diesen Screenshot: {path}"
    static let defaultWebsiteSystemPrompt = """
Analysiere diese Website:
URL: {url}
Titel: {title}
Inhalt:
{content}
"""

    private enum Keys {
        static let hotkeyPrefix = "hotkey."
        static let cliPathOverride = "claudeCLIPathOverride"
        static let model = "claudeModel"
        static let streamingEnabled = "streamingEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let screenshotSystemPromptEnabled = "screenshotSystemPromptEnabled"
        static let screenshotSystemPrompt = "screenshotSystemPrompt"
        static let websiteSystemPromptEnabled = "websiteSystemPromptEnabled"
        static let websiteSystemPrompt = "websiteSystemPrompt"
        static let websiteURLPromptOverrides = "websiteURLPromptOverrides"
        static let screenshotOpenChatAfterSend = "screenshotOpenChatAfterSend"
        static let screenshotCopyToClipboardAfterSend = "screenshotCopyToClipboardAfterSend"
        static let screenshotPlayAudioAfterSend = "screenshotPlayAudioAfterSend"
        static let websiteOpenChatAfterSend = "websiteOpenChatAfterSend"
        static let websiteCopyToClipboardAfterSend = "websiteCopyToClipboardAfterSend"
        static let websitePlayAudioAfterSend = "websitePlayAudioAfterSend"
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
    @Published var screenshotSystemPromptEnabled: Bool {
        didSet {
            UserDefaults.standard.set(screenshotSystemPromptEnabled, forKey: Keys.screenshotSystemPromptEnabled)
            notifyChange()
        }
    }
    @Published var screenshotSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(screenshotSystemPrompt, forKey: Keys.screenshotSystemPrompt)
            notifyChange()
        }
    }
    @Published var websiteSystemPromptEnabled: Bool {
        didSet {
            UserDefaults.standard.set(websiteSystemPromptEnabled, forKey: Keys.websiteSystemPromptEnabled)
            notifyChange()
        }
    }
    @Published var websiteSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(websiteSystemPrompt, forKey: Keys.websiteSystemPrompt)
            notifyChange()
        }
    }
    @Published var websiteURLPromptOverrides: [WebsiteURLPromptOverride] {
        didSet {
            persistWebsiteURLPromptOverrides()
            notifyChange()
        }
    }
    @Published var screenshotOpenChatAfterSend: Bool {
        didSet {
            UserDefaults.standard.set(screenshotOpenChatAfterSend, forKey: Keys.screenshotOpenChatAfterSend)
            notifyChange()
        }
    }
    @Published var screenshotCopyToClipboardAfterSend: Bool {
        didSet {
            UserDefaults.standard.set(screenshotCopyToClipboardAfterSend, forKey: Keys.screenshotCopyToClipboardAfterSend)
            notifyChange()
        }
    }
    @Published var screenshotPlayAudioAfterSend: Bool {
        didSet {
            UserDefaults.standard.set(screenshotPlayAudioAfterSend, forKey: Keys.screenshotPlayAudioAfterSend)
            notifyChange()
        }
    }
    @Published var websiteOpenChatAfterSend: Bool {
        didSet {
            UserDefaults.standard.set(websiteOpenChatAfterSend, forKey: Keys.websiteOpenChatAfterSend)
            notifyChange()
        }
    }
    @Published var websiteCopyToClipboardAfterSend: Bool {
        didSet {
            UserDefaults.standard.set(websiteCopyToClipboardAfterSend, forKey: Keys.websiteCopyToClipboardAfterSend)
            notifyChange()
        }
    }
    @Published var websitePlayAudioAfterSend: Bool {
        didSet {
            UserDefaults.standard.set(websitePlayAudioAfterSend, forKey: Keys.websitePlayAudioAfterSend)
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

        if UserDefaults.standard.object(forKey: Keys.screenshotSystemPromptEnabled) != nil {
            screenshotSystemPromptEnabled = UserDefaults.standard.bool(forKey: Keys.screenshotSystemPromptEnabled)
        } else {
            screenshotSystemPromptEnabled = true
        }

        screenshotSystemPrompt = UserDefaults.standard.string(forKey: Keys.screenshotSystemPrompt)
            ?? Self.defaultScreenshotSystemPrompt

        if UserDefaults.standard.object(forKey: Keys.websiteSystemPromptEnabled) != nil {
            websiteSystemPromptEnabled = UserDefaults.standard.bool(forKey: Keys.websiteSystemPromptEnabled)
        } else {
            websiteSystemPromptEnabled = true
        }

        websiteSystemPrompt = UserDefaults.standard.string(forKey: Keys.websiteSystemPrompt)
            ?? Self.defaultWebsiteSystemPrompt

        if let data = UserDefaults.standard.data(forKey: Keys.websiteURLPromptOverrides),
           let overrides = try? JSONDecoder().decode([WebsiteURLPromptOverride].self, from: data) {
            websiteURLPromptOverrides = overrides
        } else {
            websiteURLPromptOverrides = []
        }

        screenshotOpenChatAfterSend = Self.boolSetting(
            forKey: Keys.screenshotOpenChatAfterSend,
            defaultValue: true
        )
        screenshotCopyToClipboardAfterSend = Self.boolSetting(
            forKey: Keys.screenshotCopyToClipboardAfterSend,
            defaultValue: false
        )
        screenshotPlayAudioAfterSend = Self.boolSetting(
            forKey: Keys.screenshotPlayAudioAfterSend,
            defaultValue: false
        )
        websiteOpenChatAfterSend = Self.boolSetting(
            forKey: Keys.websiteOpenChatAfterSend,
            defaultValue: true
        )
        websiteCopyToClipboardAfterSend = Self.boolSetting(
            forKey: Keys.websiteCopyToClipboardAfterSend,
            defaultValue: false
        )
        websitePlayAudioAfterSend = Self.boolSetting(
            forKey: Keys.websitePlayAudioAfterSend,
            defaultValue: false
        )
    }

    func postSendActions(for feature: FeatureSendSource) -> PostSendActions {
        switch feature {
        case .screenshot:
            return PostSendActions(
                openChat: screenshotOpenChatAfterSend,
                copyToClipboard: screenshotCopyToClipboardAfterSend,
                playAudio: screenshotPlayAudioAfterSend
            )
        case .website:
            return PostSendActions(
                openChat: websiteOpenChatAfterSend,
                copyToClipboard: websiteCopyToClipboardAfterSend,
                playAudio: websitePlayAudioAfterSend
            )
        }
    }

    private static func boolSetting(forKey key: String, defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return defaultValue
    }

    func addWebsiteURLPromptOverride() {
        websiteURLPromptOverrides.append(WebsiteURLPromptOverride())
    }

    func removeWebsiteURLPromptOverride(id: UUID) {
        websiteURLPromptOverrides.removeAll { $0.id == id }
    }

    private func persistWebsiteURLPromptOverrides() {
        if let data = try? JSONEncoder().encode(websiteURLPromptOverrides) {
            UserDefaults.standard.set(data, forKey: Keys.websiteURLPromptOverrides)
        }
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
