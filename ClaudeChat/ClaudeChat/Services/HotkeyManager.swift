import AppKit
import HotKey

enum AppShortcuts {
  /// Chat-Fenster ein-/ausblenden (selten belegt: ⌃⌥⌘K)
  static let toggleChat = (key: Key.k, modifiers: NSEvent.ModifierFlags([.control, .option, .command]))
  static let toggleChatLabel = "⌃⌥⌘K"
}

@MainActor
final class HotkeyManager {
    private var toggleHotKey: HotKey?
    private let onToggle: () -> Void

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        registerDefaultHotkeys()
    }

    func registerDefaultHotkeys() {
        toggleHotKey = HotKey(key: AppShortcuts.toggleChat.key, modifiers: AppShortcuts.toggleChat.modifiers)
        toggleHotKey?.keyDownHandler = { [weak self] in
            self?.onToggle()
        }
    }
}
