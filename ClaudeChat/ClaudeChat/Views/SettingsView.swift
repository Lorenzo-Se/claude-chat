import AppKit
import HotKey
import SwiftUI

struct ShortcutRecorderView: View {
    let title: String
    @Binding var combo: KeyCombo
    var onReset: () -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(isRecording ? "Tastenkombination drücken …" : combo.displayLabel)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 140)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(isRecording ? .orange : .primary)

            Button("Zurücksetzen", action: onReset)
                .buttonStyle(.borderless)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        NSApp.activate(ignoringOtherApps: true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                return event
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.isEmpty else { return event }

            if let key = Key(carbonKeyCode: UInt32(event.keyCode)) {
                combo = KeyCombo(key: key, modifiers: flags)
                stopRecording()
                return nil
            }

            return event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var draftCLIPath = ""
    @State private var launchAtLoginError: String?
    @State private var hotkeyDrafts: [HotkeyAction: KeyCombo] = [:]

    var body: some View {
        Form {
            Section("Tastenkürzel") {
                ForEach(HotkeyAction.allCases) { action in
                    ShortcutRecorderView(
                        title: action.title,
                        combo: binding(for: action),
                        onReset: { settings.resetHotkey(action) }
                    )
                }

                Button("Alle Tastenkürzel zurücksetzen") {
                    settings.resetAllHotkeys()
                    reloadHotkeyDrafts()
                }
            }

            Section("Claude CLI") {
                TextField("Pfad (leer = automatisch)", text: $draftCLIPath)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Übernehmen") {
                        settings.cliPathOverride = draftCLIPath
                    }
                    Button("Cache leeren") {
                        ClaudeCLIResolver.invalidateCache()
                    }
                }

                Text("Leer lassen für automatische Erkennung via Login-Shell (`which claude`).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Modell") {
                Picker("Modell", selection: $settings.model) {
                    ForEach(ClaudeModelChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Streaming") {
                Toggle("Live-Antworten (stream-json)", isOn: $settings.streamingEnabled)
                Text("Aus = blockierendes JSON (Phase-1-Fallback, keine Live-Anzeige).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System") {
                Toggle("Beim Login starten", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, enabled in
                        applyLaunchAtLogin(enabled)
                    }

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .padding()
        .onAppear {
            draftCLIPath = settings.cliPathOverride
            settings.syncLaunchAtLoginFromSystem()
            reloadHotkeyDrafts()
        }
        .onChange(of: settings.cliPathOverride) { _, newValue in
            draftCLIPath = newValue
        }
        .onChange(of: settings.hotkeys) { _, _ in
            reloadHotkeyDrafts()
        }
    }

    private func binding(for action: HotkeyAction) -> Binding<KeyCombo> {
        Binding(
            get: { hotkeyDrafts[action] ?? settings.combo(for: action) },
            set: { newValue in
                hotkeyDrafts[action] = newValue
                settings.setCombo(newValue, for: action)
            }
        )
    }

    private func reloadHotkeyDrafts() {
        var drafts: [HotkeyAction: KeyCombo] = [:]
        for action in HotkeyAction.allCases {
            drafts[action] = settings.combo(for: action)
        }
        hotkeyDrafts = drafts
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            settings.syncLaunchAtLoginFromSystem()
        } catch {
            launchAtLoginError = error.localizedDescription
            settings.syncLaunchAtLoginFromSystem()
        }
    }
}

#Preview {
    SettingsView()
}
