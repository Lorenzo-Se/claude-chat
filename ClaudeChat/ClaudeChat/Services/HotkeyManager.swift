import AppKit
import HotKey

enum AppShortcuts {
    /// Chat-Fenster ein-/ausblenden (selten belegt: ⌃⌥⌘K)
    static let toggleChat = (key: Key.k, modifiers: NSEvent.ModifierFlags([.control, .option, .command]))
    static let toggleChatLabel = "⌃⌥⌘K"

    static func matchesToggleChat(_ event: NSEvent) -> Bool {
        let required = toggleChat.modifiers.intersection(.deviceIndependentFlagsMask)
        let actual = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return actual == required && event.keyCode == UInt16(toggleChat.key.carbonKeyCode)
    }

    static let fullscreenCapture = (key: Key.s, modifiers: NSEvent.ModifierFlags([.option, .shift]))
    static let regionCapture = (key: Key.d, modifiers: NSEvent.ModifierFlags([.option, .shift]))
    static let websiteExtract = (key: Key.w, modifiers: NSEvent.ModifierFlags([.option, .shift]))
}

@MainActor
final class HotkeyManager {
    private var toggleHotKey: HotKey?
    private var fullscreenHotKey: HotKey?
    private var regionHotKey: HotKey?
    private var websiteExtractHotKey: HotKey?

    private let onToggle: () -> Void
    private let onFullscreenCapture: () -> Void
    private let onRegionCapture: () -> Void
    private let onWebsiteExtract: () -> Void

    init(
        onToggle: @escaping () -> Void,
        onFullscreenCapture: @escaping () -> Void,
        onRegionCapture: @escaping () -> Void,
        onWebsiteExtract: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onFullscreenCapture = onFullscreenCapture
        self.onRegionCapture = onRegionCapture
        self.onWebsiteExtract = onWebsiteExtract
        registerDefaultHotkeys()
    }

    func registerDefaultHotkeys() {
        toggleHotKey = HotKey(key: AppShortcuts.toggleChat.key, modifiers: AppShortcuts.toggleChat.modifiers)
        toggleHotKey?.keyDownHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.onToggle()
            }
        }

        fullscreenHotKey = HotKey(key: AppShortcuts.fullscreenCapture.key, modifiers: AppShortcuts.fullscreenCapture.modifiers)
        fullscreenHotKey?.keyDownHandler = { [weak self] in
            self?.onFullscreenCapture()
        }

        regionHotKey = HotKey(key: AppShortcuts.regionCapture.key, modifiers: AppShortcuts.regionCapture.modifiers)
        regionHotKey?.keyDownHandler = { [weak self] in
            self?.onRegionCapture()
        }

        websiteExtractHotKey = HotKey(key: AppShortcuts.websiteExtract.key, modifiers: AppShortcuts.websiteExtract.modifiers)
        websiteExtractHotKey?.keyDownHandler = { [weak self] in
            self?.onWebsiteExtract()
        }
    }

    /// Globaler Hotkey pausieren, wenn das Panel sichtbar ist — lokaler Monitor übernimmt dann.
    func setTogglePaused(_ paused: Bool) {
        toggleHotKey?.isPaused = paused
    }
}
