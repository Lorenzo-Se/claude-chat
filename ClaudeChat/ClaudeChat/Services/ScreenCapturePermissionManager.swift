import AppKit
import CoreGraphics

enum ScreenCapturePermissionManager {
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func ensurePermission() -> Bool {
        if hasPermission() { return true }
        let granted = requestPermission()
        if !granted || !hasPermission() {
            showPermissionDeniedAlert()
            return false
        }
        showRestartRequiredAlert()
        return false
    }

    static func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Bildschirmaufnahme-Berechtigung erforderlich"
        alert.informativeText = """
        Claude Chat benötigt Zugriff auf Bildschirmaufnahme für Screenshots.

        Öffne Systemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme und aktiviere Claude Chat.

        Nach dem Erteilen der Berechtigung muss die App neu gestartet werden.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Systemeinstellungen öffnen")
        alert.addButton(withTitle: "Abbrechen")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static func showRestartRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = "App-Neustart erforderlich"
        alert.informativeText = "Die Bildschirmaufnahme-Berechtigung wurde erteilt. Bitte starte Claude Chat neu, damit Screenshots funktionieren."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
