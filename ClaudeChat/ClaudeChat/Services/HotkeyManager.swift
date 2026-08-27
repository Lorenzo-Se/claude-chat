import AppKit
import HotKey

@MainActor
final class HotkeyManager {
    private var toggleHotKey: HotKey?
    private var fullscreenHotKey: HotKey?
    private var regionHotKey: HotKey?
    private var websiteExtractHotKey: HotKey?
    private var sendActiveFileHotKey: HotKey?
    private var newConversationHotKey: HotKey?

    private let settings: AppSettings
    private let onToggle: () -> Void
    private let onFullscreenCapture: () -> Void
    private let onRegionCapture: () -> Void
    private let onWebsiteExtract: () -> Void
    private let onSendActiveFile: () -> Void
    private let onNewConversation: () -> Void

    private var settingsObserver: NSObjectProtocol?

    init(
        settings: AppSettings = .shared,
        onToggle: @escaping () -> Void,
        onFullscreenCapture: @escaping () -> Void,
        onRegionCapture: @escaping () -> Void,
        onWebsiteExtract: @escaping () -> Void,
        onSendActiveFile: @escaping () -> Void,
        onNewConversation: @escaping () -> Void
    ) {
        self.settings = settings
        self.onToggle = onToggle
        self.onFullscreenCapture = onFullscreenCapture
        self.onRegionCapture = onRegionCapture
        self.onWebsiteExtract = onWebsiteExtract
        self.onSendActiveFile = onSendActiveFile
        self.onNewConversation = onNewConversation

        registerHotkeys()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .appSettingsDidChange,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerHotkeys()
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    func registerHotkeys() {
        clearHotkeys()
        register(.toggleChat, handler: { [weak self] in
            DispatchQueue.main.async { self?.onToggle() }
        }, assign: { self.toggleHotKey = $0 })

        register(.fullscreenCapture, handler: { [weak self] in self?.onFullscreenCapture() }, assign: { self.fullscreenHotKey = $0 })
        register(.regionCapture, handler: { [weak self] in self?.onRegionCapture() }, assign: { self.regionHotKey = $0 })
        register(.websiteExtract, handler: { [weak self] in self?.onWebsiteExtract() }, assign: { self.websiteExtractHotKey = $0 })
        register(.sendActiveFile, handler: { [weak self] in self?.onSendActiveFile() }, assign: { self.sendActiveFileHotKey = $0 })
        register(.newConversation, handler: { [weak self] in self?.onNewConversation() }, assign: { self.newConversationHotKey = $0 })
    }

    private func register(
        _ action: HotkeyAction,
        handler: @escaping () -> Void,
        assign: (HotKey) -> Void
    ) {
        let combo = settings.combo(for: action)
        guard let key = combo.key else { return }

        let hotKey = HotKey(key: key, modifiers: combo.modifiers)
        hotKey.keyDownHandler = handler
        assign(hotKey)
    }

    private func clearHotkeys() {
        toggleHotKey = nil
        fullscreenHotKey = nil
        regionHotKey = nil
        websiteExtractHotKey = nil
        sendActiveFileHotKey = nil
        newConversationHotKey = nil
    }

    /// Globaler Hotkey pausieren, wenn das Panel sichtbar ist — lokaler Monitor übernimmt dann.
    func setTogglePaused(_ paused: Bool) {
        toggleHotKey?.isPaused = paused
    }
}
