import AppKit
import SwiftUI

enum SettingsBridge {
    static let windowID = "settings-bridge"
}

/// Hält `openSettings` aus der SwiftUI-App-Lifecycle, damit AppKit (Statusmenü) Einstellungen korrekt öffnen kann.
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
}

/// Registriert `openSettings` in einem versteckten Fenster (muss vor der Settings-Scene deklariert sein).
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

/// Hält das Bridge-Fenster in der SwiftUI-Scene, blendet es aber unsichtbar aus.
/// `orderOut` oder `dismissWindow` würden das letzte Fenster entfernen und die App beenden.
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
