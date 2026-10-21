import AVFoundation
import ClaudeChatCore
import Foundation
import Observation

enum ClaudeModelChoice: String, CaseIterable, Identifiable {
    case `default`, sonnet, opus, haiku

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: "Default (CLI default)"
        case .sonnet: "Sonnet"
        case .opus: "Opus"
        case .haiku: "Haiku"
        }
    }

    /// Value for `--model`; nil omits the flag.
    var cliValue: String? { self == .default ? nil : rawValue }
}

enum FeatureSource {
    case screenshot, website, file
}

/// What happens after an automatically sent feature prompt (screenshot, website, file) got its answer.
struct FeatureSettings: Equatable {
    var useSystemPrompt: Bool
    var systemPrompt: String
    var openChatAfterSend: Bool
    var copyToClipboardAfterSend: Bool
    var speakAfterSend: Bool
}

/// UserDefaults-backed settings. Keys are unchanged from earlier versions so existing settings carry over.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored var onShortcutsChange: (() -> Void)?

    private(set) var shortcuts: [HotkeyAction: Shortcut]

    var cliPathOverride: String { didSet { defaults.set(cliPathOverride.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "claudeCLIPathOverride") } }
    var model: ClaudeModelChoice { didSet { defaults.set(model.rawValue, forKey: "claudeModel") } }
    var streamingEnabled: Bool { didSet { defaults.set(streamingEnabled, forKey: "streamingEnabled") } }

    var screenshot: FeatureSettings { didSet { store(screenshot, prefix: "screenshot") } }
    var website: FeatureSettings { didSet { store(website, prefix: "website") } }
    var file: FeatureSettings { didSet { store(file, prefix: "file") } }
    var websiteURLPromptOverrides: [WebsiteURLPromptOverride] {
        didSet { defaults.set(try? JSONEncoder().encode(websiteURLPromptOverrides), forKey: "websiteURLPromptOverrides") }
    }

    /// Empty = pick the best installed voice for the response's language.
    var speechVoiceIdentifier: String { didSet { defaults.set(speechVoiceIdentifier, forKey: "speechVoiceIdentifier") } }
    var speechRate: Float { didSet { defaults.set(speechRate, forKey: "speechRate") } }
    var speechLength: SpeechLength { didSet { defaults.set(speechLength.rawValue, forKey: "speechLength") } }

    init() {
        var loaded: [HotkeyAction: Shortcut] = [:]
        for action in HotkeyAction.allCases {
            if let data = defaults.data(forKey: "hotkey.\(action.rawValue)"),
               let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) {
                loaded[action] = shortcut
            } else {
                loaded[action] = action.defaultShortcut
            }
        }
        shortcuts = loaded

        cliPathOverride = defaults.string(forKey: "claudeCLIPathOverride") ?? ""
        model = defaults.string(forKey: "claudeModel").flatMap(ClaudeModelChoice.init(rawValue:)) ?? .default
        streamingEnabled = defaults.object(forKey: "streamingEnabled") as? Bool ?? true

        screenshot = Self.load(prefix: "screenshot", defaultPrompt: PromptTemplates.defaultScreenshot, from: defaults)
        website = Self.load(prefix: "website", defaultPrompt: PromptTemplates.defaultWebsite, from: defaults)
        file = Self.load(prefix: "file", defaultPrompt: PromptTemplates.defaultFile, from: defaults)
        websiteURLPromptOverrides = defaults.data(forKey: "websiteURLPromptOverrides")
            .flatMap { try? JSONDecoder().decode([WebsiteURLPromptOverride].self, from: $0) } ?? []

        speechVoiceIdentifier = defaults.string(forKey: "speechVoiceIdentifier") ?? ""
        speechRate = defaults.object(forKey: "speechRate") != nil ? defaults.float(forKey: "speechRate") : AVSpeechUtteranceDefaultSpeechRate
        speechLength = defaults.string(forKey: "speechLength").flatMap(SpeechLength.init(rawValue:)) ?? .full
    }

    func feature(_ source: FeatureSource) -> FeatureSettings {
        switch source {
        case .screenshot: screenshot
        case .website: website
        case .file: file
        }
    }

    func shortcut(for action: HotkeyAction) -> Shortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    /// The action already using `shortcut`, if any (other than `action` itself).
    func conflict(for shortcut: Shortcut, excluding action: HotkeyAction) -> HotkeyAction? {
        HotkeyAction.allCases.first { $0 != action && self.shortcut(for: $0) == shortcut }
    }

    func setShortcut(_ shortcut: Shortcut, for action: HotkeyAction) {
        shortcuts[action] = shortcut
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: "hotkey.\(action.rawValue)")
        onShortcutsChange?()
    }

    func resetShortcuts() {
        for action in HotkeyAction.allCases {
            shortcuts[action] = action.defaultShortcut
            defaults.removeObject(forKey: "hotkey.\(action.rawValue)")
        }
        onShortcutsChange?()
    }

    // Per-feature keys: "<prefix>SystemPromptEnabled", "<prefix>SystemPrompt", "<prefix>OpenChatAfterSend", …
    private static func load(prefix: String, defaultPrompt: String, from defaults: UserDefaults) -> FeatureSettings {
        FeatureSettings(
            useSystemPrompt: defaults.object(forKey: "\(prefix)SystemPromptEnabled") as? Bool ?? true,
            systemPrompt: defaults.string(forKey: "\(prefix)SystemPrompt") ?? defaultPrompt,
            openChatAfterSend: defaults.object(forKey: "\(prefix)OpenChatAfterSend") as? Bool ?? true,
            copyToClipboardAfterSend: defaults.object(forKey: "\(prefix)CopyToClipboardAfterSend") as? Bool ?? false,
            speakAfterSend: defaults.object(forKey: "\(prefix)PlayAudioAfterSend") as? Bool ?? false
        )
    }

    private func store(_ feature: FeatureSettings, prefix: String) {
        defaults.set(feature.useSystemPrompt, forKey: "\(prefix)SystemPromptEnabled")
        defaults.set(feature.systemPrompt, forKey: "\(prefix)SystemPrompt")
        defaults.set(feature.openChatAfterSend, forKey: "\(prefix)OpenChatAfterSend")
        defaults.set(feature.copyToClipboardAfterSend, forKey: "\(prefix)CopyToClipboardAfterSend")
        defaults.set(feature.speakAfterSend, forKey: "\(prefix)PlayAudioAfterSend")
    }
}
