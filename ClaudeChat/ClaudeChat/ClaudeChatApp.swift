import SwiftUI

@main
struct ClaudeChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: FloatingPanelController?
    private var hotkeyManager: HotkeyManager?
    private var chatViewModel: ChatViewModel?

    let store = ConversationStore()
    let processManager = ClaudeProcessManager()
    let screenshotService = ScreenshotCaptureService()
    let settings = AppSettings.shared

    private var statusMenu: NSMenu?
    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        ScreenshotStore.shared.cleanupOldScreenshots()
        NativeMessagingHostInstaller.installIfNeeded()
        settings.syncLaunchAtLoginFromSystem()

        setupStatusItem()
        setupPanel()
        setupHotkeys()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .appSettingsDidChange,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildStatusMenu()
            }
        }

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

        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Chat ein-/ausblenden (\(settings.label(for: .toggleChat)))",
            action: #selector(togglePanel),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Einstellungen…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q"))
        statusMenu = menu
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            rebuildStatusMenu()
            statusMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        } else {
            togglePanel()
        }
    }

    @objc private func openSettings() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupPanel() {
        guard let conversation = store.activeConversation() else { return }

        let viewModel = ChatViewModel(
            conversation: conversation,
            store: store,
            processManager: processManager,
            settings: settings
        )
        chatViewModel = viewModel

        let chatView = ChatView(viewModel: viewModel, store: store)
        let controller = FloatingPanelController(rootView: chatView, settings: settings)
        controller.onToggleShortcut = { [weak self] in
            self?.togglePanel()
        }
        controller.onVisibilityChanged = { [weak self] visible in
            self?.hotkeyManager?.setTogglePaused(visible)
        }
        panelController = controller
    }

    private func setupHotkeys() {
        hotkeyManager = HotkeyManager(
            settings: settings,
            onToggle: { [weak self] in
                self?.togglePanel()
            },
            onFullscreenCapture: { [weak self] in
                Task { await self?.handleFullscreenCapture() }
            },
            onRegionCapture: { [weak self] in
                Task { await self?.handleRegionCapture() }
            },
            onWebsiteExtract: { [weak self] in
                Task { await self?.handleWebsiteExtract() }
            },
            onNewConversation: { [weak self] in
                self?.handleNewConversation()
            }
        )
    }

    private func handleNewConversation() {
        panelController?.show()
        try? chatViewModel?.newConversation()
    }

    private func handleFullscreenCapture() async {
        do {
            let path = try await screenshotService.captureFullscreen()
            panelController?.show()
            await chatViewModel?.sendScreenshot(path: path)
        } catch {
            showCaptureError(error)
        }
    }

    private func handleRegionCapture() async {
        do {
            let path = try await screenshotService.captureRegion()
            panelController?.show()
            await chatViewModel?.sendScreenshot(path: path)
        } catch ScreenshotCaptureError.captureFailed("Auswahl abgebrochen") {
            // Keine Meldung bei Abbruch
        } catch {
            showCaptureError(error)
        }
    }

    private func handleWebsiteExtract() async {
        do {
            let content = try await WebsiteContentService.extractFromActiveTab()
            let prompt = WebsiteContentService.buildPrompt(for: content)
            panelController?.show()
            await chatViewModel?.sendWebsiteContent(prompt: prompt, pageTitle: content.title)
        } catch {
            showWebsiteExtractError(error)
        }
    }

    private func showCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Screenshot fehlgeschlagen"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showWebsiteExtractError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Website-Extraktion fehlgeschlagen"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
