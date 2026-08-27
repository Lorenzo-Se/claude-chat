import SwiftUI

/// Hält `openSettings` aus der SwiftUI-App-Lifecycle, damit AppKit (Statusmenü) Einstellungen korrekt öffnen kann.
@MainActor
enum SettingsOpener {
    private static var openAction: OpenSettingsAction?

    static func register(_ action: OpenSettingsAction) {
        openAction = action
    }

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let openAction {
            openAction()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    /// Lädt die Settings-Scene beim Start, damit `openSettings` registriert ist (ohne dauerhaft sichtbares Fenster).
    static func preloadRegistration() {
        guard openAction == nil else { return }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            hideTransientSettingsWindows()
        }
    }

    private static func hideTransientSettingsWindows() {
        for window in NSApp.windows {
            let className = NSStringFromClass(type(of: window))
            if className.contains("Settings") {
                window.orderOut(nil)
            }
        }
    }
}

/// Registriert `openSettings` beim ersten Anzeigen der Settings-Scene.
struct SettingsRegistrationView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                SettingsOpener.register(openSettings)
            }
    }
}
