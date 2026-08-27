import AppKit
import SwiftUI

enum SettingsBridge {
    static let windowID = "settings-bridge"
}

/// Keeps `openSettings` from the SwiftUI app lifecycle so AppKit (status menu) can open settings correctly.
@MainActor
enum SettingsOpener {
    private static var openAction: OpenSettingsAction?

    static func register(_ action: OpenSettingsAction) {
        openAction = action
    }

    static func open() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let openAction {
            openAction()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    static func restoreAccessoryPolicy() {
        NSApp.setActivationPolicy(.accessory)
    }

    static func close() {
        if let window = NSApp.keyWindow, isSettingsWindow(window) {
            window.close()
            return
        }

        for window in NSApp.windows where isSettingsWindow(window) {
            window.close()
            return
        }
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.isVisible
            && window.alphaValue > 0
            && !window.ignoresMouseEvents
    }
}

/// Registers `openSettings` in a hidden window (must be declared before the Settings scene).
struct SettingsRegistrationView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(BridgeWindowConcealer())
            .onAppear {
                SettingsOpener.register(openSettings)
            }
    }
}

/// Keeps the bridge window in the SwiftUI scene but hides it.
/// `orderOut` or `dismissWindow` would remove the last window and quit the app.
private struct BridgeWindowConcealer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        concealWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        concealWindow(for: nsView)
    }

    private func concealWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.alphaValue = 0
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.collectionBehavior.insert(.ignoresCycle)
        }
    }
}
