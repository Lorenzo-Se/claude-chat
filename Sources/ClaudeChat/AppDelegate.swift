import AppKit
import ClaudeChatCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var speech = SpeechService(settings: settings)
    private lazy var chat = ChatController(
        repository: ConversationRepository(directory: AppPaths.conversations),
        settings: settings,
        speech: speech
    )
    private let focus = InputFocus()
    private let screenshots = ScreenshotService()
    private var panel: PanelController!
    private var hotkeys: HotkeyManager!
    private var statusItem: NSStatusItem!
    private var settingsWindow: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        AppPaths.screenshots.purgeExpired()
        AppPaths.attachments.purgeExpired()
        NativeHostInstaller.installInBackground()
        // Resolve the CLI early so the first message does not wait for the login shell.
        Task { [chat, settings] in _ = try? await chat.resolver.resolve(override: settings.cliPathOverride) }

        panel = PanelController(
            rootView: ChatView(controller: chat, speech: speech, focus: focus, onHide: { [weak self] in self?.panel.hide() }),
            focus: focus
        )
        chat.showPanel = { [weak self] in self?.panel.show() }
        chat.focusInput = { [focus] in DispatchQueue.main.async { focus.focus() } }

        settingsWindow = SettingsWindowController { [unowned self] in
            SettingsView(
                settings: settings,
                speech: speech,
                resolver: chat.resolver,
                setHotkeysPaused: { [weak self] paused in self?.setHotkeysPaused(paused) }
            )
        }

        hotkeys = HotkeyManager { [weak self] action in self?.perform(action) }
        hotkeys.register(settings.shortcuts)
        settings.onShortcutsChange = { [weak self] in
            guard let self else { return }
            hotkeys.register(settings.shortcuts)
        }

        setUpStatusItem()
        setUpMainMenu()
        observeRunningState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        chat.prepareForTermination()
        speech.stop()
    }

    // MARK: - Hotkey actions

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .toggleChat:
            panel.toggle()
        case .newConversation:
            chat.newConversation()
            panel.show()
        case .fullscreenCapture:
            Task { await captureScreenshot(region: false) }
        case .regionCapture:
            Task { await captureScreenshot(region: true) }
        case .websiteExtract:
            Task { await extractWebsite() }
        case .sendActiveFile:
            sendActiveFiles()
        }
    }

    private func setHotkeysPaused(_ paused: Bool) {
        if paused {
            hotkeys.unregisterAll()
        } else {
            hotkeys.register(settings.shortcuts)
        }
    }

    private func captureScreenshot(region: Bool) async {
        do {
            let path = region ? try await screenshots.captureRegion() : try await screenshots.captureFullScreen()
            chat.handleScreenshot(path: path)
        } catch ScreenshotError.cancelled {
            return
        } catch ScreenshotError.permissionMissing {
            showAlert(
                "Screen recording permission required",
                ScreenshotError.permissionMissing.errorDescription ?? "",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        } catch {
            showAlert("Screenshot failed", error)
        }
    }

    private func extractWebsite() async {
        do {
            chat.handleWebsite(try await WebsiteExtractor.extractActiveTab())
        } catch {
            showAlert("Website extraction failed", error)
        }
    }

    private func sendActiveFiles() {
        do {
            try chat.handleFiles(paths: try FileContextService.activeFilePaths())
        } catch FileContextError.automationDenied(let app) {
            showAlert(
                "Automation permission required",
                FileContextError.automationDenied(app: app).errorDescription ?? "",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            )
        } catch {
            showAlert("Send file failed", error)
        }
    }

    private func showAlert(_ title: String, _ error: Error) {
        showAlert(title, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func showAlert(_ title: String, _ message: String, settingsURL: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if settingsURL != nil {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
        }
        if alert.runModal() == .alertFirstButtonReturn, let settingsURL, let url = URL(string: settingsURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Main menu

    /// Invisible for an accessory app, but AppKit routes ⌘A/⌘C/⌘V/⌘X/⌘Z through it —
    /// without it these shortcuts do nothing in the chat input and settings fields.
    private func setUpMainMenu() {
        let appMenu = NSMenu(title: "Claude Chat")
        let settingsItem = item("Settings…") { [weak self] in self?.settingsWindow.show() }
        settingsItem.keyEquivalent = ","
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Claude Chat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu] {
            let holder = NSMenuItem()
            holder.submenu = submenu
            mainMenu.addItem(holder)
        }
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusIcon()
    }

    /// Left click toggles the chat; right click (or ⌃-click) opens a menu built fresh each time.
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            statusItem.menu = makeMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            panel.toggle()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Show / Hide Chat (\(settings.shortcut(for: .toggleChat).displayLabel))") { [weak self] in self?.panel.toggle() })
        menu.addItem(item("New Conversation") { [weak self] in self?.perform(.newConversation) })
        if speech.isSpeaking {
            menu.addItem(item("Stop Speaking") { [weak self] in self?.speech.stop() })
        }
        if chat.anyRunning {
            menu.addItem(item("Stop All Responses") { [weak self] in self?.chat.stopAll() })
        }
        menu.addItem(.separator())
        let settingsItem = item("Settings…") { [weak self] in self?.settingsWindow.show() }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = item("Quit Claude Chat") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        return menu
    }

    private func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target
        return item
    }

    /// Shows activity in the menu bar while any request runs — feature requests run without the panel.
    private func observeRunningState() {
        withObservationTracking {
            _ = chat.anyRunning
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateStatusIcon()
                self?.observeRunningState()
            }
        }
    }

    private func updateStatusIcon() {
        let symbol = chat.anyRunning ? "ellipsis.bubble.fill" : "bubble.left.and.bubble.right"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude Chat")
    }
}

/// Retained by its menu item (`representedObject`) so closures can serve as menu actions.
private final class MenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}
