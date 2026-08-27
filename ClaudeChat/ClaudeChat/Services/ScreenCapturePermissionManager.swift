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
        alert.messageText = "Screen recording permission required"
        alert.informativeText = """
        Claude Chat needs screen recording access for screenshots.

        Open System Settings → Privacy & Security → Screen Recording and enable Claude Chat.

        After granting permission, you must restart the app.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static func showRestartRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = "App restart required"
        alert.informativeText = "Screen recording permission was granted. Please restart Claude Chat for screenshots to work."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
