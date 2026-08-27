import SwiftUI

@main
struct ClaudeChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: FloatingPanelController?
    private var hotkeyManager: HotkeyManager?

    let store = ConversationStore()
    let processManager = ClaudeProcessManager()

    private var statusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPanel()
        setupHotkeys()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidClose),
            name: .floatingPanelDidClose,
            object: nil
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Claude Chat")
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Chat ein-/ausblenden (\(AppShortcuts.toggleChatLabel))", action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q"))
        statusMenu = menu
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        } else {
            togglePanel()
        }
    }

    private func setupPanel() {
        guard let conversation = store.activeConversation() else { return }

        let viewModel = ChatViewModel(
            conversation: conversation,
            store: store,
            processManager: processManager
        )

        let chatView = ChatView(viewModel: viewModel, store: store)
        panelController = FloatingPanelController(rootView: chatView)
    }

    private func setupHotkeys() {
        hotkeyManager = HotkeyManager { [weak self] in
            self?.togglePanel()
        }
    }

    @objc private func togglePanel() {
        panelController?.toggle()
    }

    @objc private func panelDidClose() {
        panelController?.orderOutOnClose()
    }

    @objc private func quit() {
        processManager.terminateAll()
        NSApp.terminate(nil)
    }
}
