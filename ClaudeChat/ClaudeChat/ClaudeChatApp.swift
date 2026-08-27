import SwiftUI

@main
struct ClaudeChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Verstecktes Fenster vor der Settings-Scene: liefert den SwiftUI-Kontext für `openSettings`.
        Window("Hidden", id: SettingsBridge.windowID) {
            SettingsRegistrationView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1, height: 1)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .onDisappear {
                    SettingsOpener.restoreAccessoryPolicy()
                }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        ScreenshotStore.shared.cleanupOldScreenshots()
        AttachmentStore.shared.cleanupOldAttachments()
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

        let toggleItem = NSMenuItem(
            title: "Chat ein-/ausblenden (\(settings.label(for: .toggleChat)))",
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(
            title: "Einstellungen…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

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
        SettingsOpener.open()
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
        viewModel.showPanel = { [weak self] in
            self?.panelController?.show()
        }

        let chatView = ChatView(viewModel: viewModel, store: store)
        panelController = FloatingPanelController(rootView: chatView)
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
            onSendActiveFile: { [weak self] in
                Task { await self?.handleSendActiveFile() }
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
            if shouldShowPanelOnFeatureTrigger(systemPromptEnabled: settings.screenshotSystemPromptEnabled) {
                panelController?.show()
            }
            await chatViewModel?.sendScreenshot(path: path)
        } catch {
            showCaptureError(error)
        }
    }

    private func handleRegionCapture() async {
        do {
            let path = try await screenshotService.captureRegion()
            if shouldShowPanelOnFeatureTrigger(systemPromptEnabled: settings.screenshotSystemPromptEnabled) {
                panelController?.show()
            }
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
            if shouldShowPanelOnFeatureTrigger(systemPromptEnabled: settings.websiteSystemPromptEnabled) {
                panelController?.show()
            }
            await chatViewModel?.handleWebsiteContent(content)
        } catch {
            showWebsiteExtractError(error)
        }
    }

    private func handleSendActiveFile() async {
        do {
            let paths = try await FileContextService.resolveActiveFilePaths()
            if shouldShowPanelOnFeatureTrigger(systemPromptEnabled: settings.fileSystemPromptEnabled) {
                panelController?.show()
            }
            await chatViewModel?.sendFiles(paths: paths)
        } catch {
            showFileSendError(error)
        }
    }

    /// Panel beim Auslösen nur öffnen, wenn der Nutzer Inhalt vor dem Senden bearbeiten muss.
    private func shouldShowPanelOnFeatureTrigger(systemPromptEnabled: Bool) -> Bool {
        !systemPromptEnabled
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

    private func showFileSendError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Datei senden fehlgeschlagen"
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
