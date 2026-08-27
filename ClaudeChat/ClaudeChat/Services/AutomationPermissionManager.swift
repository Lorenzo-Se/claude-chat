import AppKit
import Foundation

enum AutomationPermissionManager {
    private static let finderProbeScript = "tell application \"Finder\" to get name"
    private static let previewProbeScript = "tell application \"Preview\" to get name"

    @MainActor
    static func ensurePermissions(interactive: Bool = true) async -> Bool {
        let finderOK = probeAccess(script: finderProbeScript)
        let previewOK = probeAccess(script: previewProbeScript)

        if finderOK && previewOK {
            return true
        }

        if interactive {
            NSApp.activate(ignoringOtherApps: true)
            triggerPermissionPrompt(script: finderProbeScript)
            triggerPermissionPrompt(script: previewProbeScript)

            let finderAfter = probeAccess(script: finderProbeScript)
            let previewAfter = probeAccess(script: previewProbeScript)

            if finderAfter && previewAfter {
                return true
            }

            showPermissionDeniedAlert(finderGranted: finderAfter, previewGranted: previewAfter)
        }

        return false
    }

    @MainActor
    static func requestPermissionsFromSettings() {
        NSApp.activate(ignoringOtherApps: true)
        triggerPermissionPrompt(script: finderProbeScript)
        triggerPermissionPrompt(script: previewProbeScript)

        let finderOK = probeAccess(script: finderProbeScript)
        let previewOK = probeAccess(script: previewProbeScript)

        if !finderOK || !previewOK {
            showPermissionDeniedAlert(finderGranted: finderOK, previewGranted: previewOK)
        }
    }

    @MainActor
    private static func probeAccess(script: String) -> Bool {
        do {
            _ = try AppleScriptRunner.execute(script)
            return true
        } catch let error as AppleScriptRunner.Error {
            return !error.isAutomationDenied
        } catch {
            return false
        }
    }

    @MainActor
    private static func triggerPermissionPrompt(script: String) {
        do {
            _ = try AppleScriptRunner.execute(script)
        } catch {
            // Dialog or denial — result is checked again afterward.
        }
    }

    @MainActor
    private static func showPermissionDeniedAlert(finderGranted: Bool, previewGranted: Bool) {
        var missing: [String] = []
        if !finderGranted { missing.append("Finder") }
        if !previewGranted { missing.append("Preview") }

        let missingList = missing.joined(separator: ", ")

        let alert = NSAlert()
        alert.messageText = "Automation permission required"
        alert.informativeText = """
        Claude Chat needs access to \(missingList) to detect selected files or open documents.

        macOS shows a dialog the first time — allow control of Finder and Preview.

        If no dialog appears: System Settings → Privacy & Security → Automation → enable Claude Chat and allow the missing apps.

        Important: rebuild and restart the app after updating so it appears in the Automation list.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            openAutomationSettings()
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum AppleScriptRunner {
    enum Error: LocalizedError {
        case scriptCreationFailed
        case automationDenied
        case failed(String, Int)

        var isAutomationDenied: Bool {
            if case .automationDenied = self { return true }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .scriptCreationFailed:
                return "AppleScript could not be created."
            case .automationDenied:
                return "Automation permission denied."
            case .failed(let message, let code):
                return "AppleScript error (\(code)): \(message)"
            }
        }
    }

    @MainActor
    static func execute(_ source: String) throws -> String? {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw Error.scriptCreationFailed
        }

        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0

            if code == -1743 || message.localizedCaseInsensitiveContains("not authorized") {
                throw Error.automationDenied
            }

            throw Error.failed(message, code)
        }

        guard let stringValue = output.stringValue else { return nil }
        return stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
