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
                Text(isRecording ? "Press shortcut…" : combo.displayLabel)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 140)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(isRecording ? .orange : .primary)

            Button("Reset", action: onReset)
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

            if event.keyCode == 53 { // Escape — cancel recording without closing the window
                stopRecording()
                return nil
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
    @State private var escapeMonitor: Any?

    var body: some View {
        Form {
            Section("Keyboard shortcuts") {
                ForEach(HotkeyAction.allCases) { action in
                    ShortcutRecorderView(
                        title: action.title,
                        combo: binding(for: action),
                        onReset: { settings.resetHotkey(action) }
                    )
                }

                Button("Reset all shortcuts") {
                    settings.resetAllHotkeys()
                    reloadHotkeyDrafts()
                }
            }

            Section("Claude CLI") {
                TextField("Path (empty = automatic)", text: $draftCLIPath)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Apply") {
                        settings.cliPathOverride = draftCLIPath
                    }
                    Button("Clear cache") {
                        ClaudeCLIResolver.invalidateCache()
                    }
                }

                Text("Leave empty for automatic detection via login shell (`which claude`).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                Picker("Model", selection: $settings.model) {
                    ForEach(ClaudeModelChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Streaming") {
                Toggle("Live responses (stream-json)", isOn: $settings.streamingEnabled)
                Text("Off = blocking JSON (Phase 1 fallback, no live display).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, enabled in
                        applyLaunchAtLogin(enabled)
                    }

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Screenshot") {
                Toggle("Use system prompt", isOn: $settings.screenshotSystemPromptEnabled)

                if settings.screenshotSystemPromptEnabled {
                    TextEditor(text: $settings.screenshotSystemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 72)

                    Text("Placeholders: {path} (screenshot path), {userText}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Screenshot is attached; input field stays empty — send manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("After sending")
                    .font(.subheadline)

                Toggle("Open chat window after send", isOn: $settings.screenshotOpenChatAfterSend)
                Toggle("Copy response to clipboard", isOn: $settings.screenshotCopyToClipboardAfterSend)
                Toggle("Speak response aloud", isOn: $settings.screenshotPlayAudioAfterSend)
            }

            Section("Website") {
                Toggle("Use system prompt", isOn: $settings.websiteSystemPromptEnabled)

                if settings.websiteSystemPromptEnabled {
                    Text("Default system prompt")
                        .font(.subheadline)

                    TextEditor(text: $settings.websiteSystemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 72)

                    Text("Placeholders: {url}, {title}, {content}")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Text("URL rules (override default prompt)")
                        .font(.subheadline)

                    ForEach($settings.websiteURLPromptOverrides) { $override in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Pattern (e.g. github.com)", text: $override.pattern)
                                    .textFieldStyle(.roundedBorder)

                                Button {
                                    settings.removeWebsiteURLPromptOverride(id: override.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete rule")
                            }

                            TextEditor(text: $override.prompt)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 56)
                        }
                    }

                    Button("Add URL rule") {
                        settings.addWebsiteURLPromptOverride()
                    }
                } else {
                    Text("Extracted content (URL, title, text) is placed in the input field — send manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("After sending")
                    .font(.subheadline)

                Toggle("Open chat window after send", isOn: $settings.websiteOpenChatAfterSend)
                Toggle("Copy response to clipboard", isOn: $settings.websiteCopyToClipboardAfterSend)
                Toggle("Speak response aloud", isOn: $settings.websitePlayAudioAfterSend)
            }

            Section("File") {
                Toggle("Use system prompt", isOn: $settings.fileSystemPromptEnabled)

                if settings.fileSystemPromptEnabled {
                    TextEditor(text: $settings.fileSystemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 72)

                    Text("Placeholders: {paths}, {path}, {filename}, {userText}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("File paths are placed in the input field — send manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("After sending")
                    .font(.subheadline)

                Toggle("Open chat window after send", isOn: $settings.fileOpenChatAfterSend)
                Toggle("Copy response to clipboard", isOn: $settings.fileCopyToClipboardAfterSend)
                Toggle("Speak response aloud", isOn: $settings.filePlayAudioAfterSend)

                Divider()

                Text("Claude Chat must be allowed to control Finder and Preview. macOS shows a dialog the first time — afterward the app appears under Automation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Request automation permissions") {
                    AutomationPermissionManager.requestPermissionsFromSettings()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 900)
        .padding()
        .onAppear {
            draftCLIPath = settings.cliPathOverride
            settings.syncLaunchAtLoginFromSystem()
            reloadHotkeyDrafts()
            startEscapeMonitor()
        }
        .onDisappear {
            stopEscapeMonitor()
        }
        .onChange(of: settings.cliPathOverride) { _, newValue in
            draftCLIPath = newValue
        }
        .onChange(of: settings.hotkeys) { _, _ in
            reloadHotkeyDrafts()
        }
        .onExitCommand {
            SettingsOpener.close()
        }
    }

    private func startEscapeMonitor() {
        stopEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            SettingsOpener.close()
            return nil
        }
    }

    private func stopEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
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
