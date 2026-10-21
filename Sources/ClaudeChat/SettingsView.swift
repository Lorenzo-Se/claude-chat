import AVFoundation
import ClaudeChatCore
import HotKey
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeView: () -> SettingsView

    init(makeView: @escaping () -> SettingsView) {
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let window = EscapeClosingWindow(contentViewController: NSHostingController(rootView: makeView()))
            window.title = "Claude Chat Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class EscapeClosingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let speech: SpeechService
    let resolver: CLIResolver
    /// Global hotkeys are paused while a shortcut is being recorded.
    let setHotkeysPaused: (Bool) -> Void

    var body: some View {
        TabView {
            GeneralSettings(settings: settings, resolver: resolver)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettings(settings: settings, setHotkeysPaused: setHotkeysPaused)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            FeatureSettingsView(settings: settings)
                .tabItem { Label("Features", systemImage: "sparkles") }
            SpeechSettings(settings: settings, speech: speech)
                .tabItem { Label("Speech", systemImage: "speaker.wave.2") }
        }
        .frame(width: 560, height: 600)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    let resolver: CLIResolver
    @State private var draftPath = ""
    @State private var detected = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Claude CLI") {
                TextField("Path", text: $draftPath, prompt: Text("Automatic"))
                HStack {
                    Button("Apply") {
                        settings.cliPathOverride = draftPath
                        Task { await detect() }
                    }
                    Button("Detect again") {
                        Task {
                            await resolver.invalidate()
                            await detect()
                        }
                    }
                }
                Text(detected.isEmpty ? "Leave empty to find `claude` via your login shell." : detected)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Responses") {
                Picker("Model", selection: $settings.model) {
                    ForEach(ClaudeModelChoice.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show responses live while they stream", isOn: $settings.streamingEnabled)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            draftPath = settings.cliPathOverride
            await detect()
        }
    }

    private func detect() async {
        do {
            let environment = try await resolver.resolve(override: settings.cliPathOverride)
            detected = "Using \(environment.executable)"
        } catch {
            detected = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @Bindable var settings: AppSettings
    let setHotkeysPaused: (Bool) -> Void
    @State private var recording: HotkeyAction?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        HStack {
                            ShortcutRecorder(
                                shortcut: settings.shortcut(for: action),
                                isRecording: recording == action,
                                onStart: { startRecording(action) },
                                onRecord: { record($0, for: action) },
                                onCancel: stopRecording
                            )
                            Button("Reset") { settings.setShortcut(action.defaultShortcut, for: action) }
                                .buttonStyle(.borderless)
                                .disabled(settings.shortcut(for: action) == action.defaultShortcut)
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let message {
                        Text(message).foregroundStyle(.orange)
                    }
                    Text("Click a shortcut, then press the new key combination (with ⌘, ⌥, ⌃ or ⇧). ⎋ cancels.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Button("Reset all shortcuts") { settings.resetShortcuts() }
        }
        .formStyle(.grouped)
        .onDisappear(perform: stopRecording)
    }

    private func startRecording(_ action: HotkeyAction) {
        message = nil
        recording = action
        setHotkeysPaused(true)
    }

    private func stopRecording() {
        guard recording != nil else { return }
        recording = nil
        setHotkeysPaused(false)
    }

    private func record(_ shortcut: Shortcut, for action: HotkeyAction) {
        if let other = settings.conflict(for: shortcut, excluding: action) {
            message = "\(shortcut.displayLabel) is already used for “\(other.title)”."
        } else {
            settings.setShortcut(shortcut, for: action)
        }
        stopRecording()
    }
}

private struct ShortcutRecorder: View {
    let shortcut: Shortcut
    let isRecording: Bool
    let onStart: () -> Void
    let onRecord: (Shortcut) -> Void
    let onCancel: () -> Void
    @State private var monitor: Any?

    var body: some View {
        Button(action: { isRecording ? onCancel() : onStart() }) {
            Text(isRecording ? "Press shortcut…" : shortcut.displayLabel)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 120)
        }
        .foregroundStyle(isRecording ? Color.accentColor : .primary)
        .onChange(of: isRecording) { _, recording in
            recording ? installMonitor() : removeMonitor()
        }
        .onDisappear(perform: removeMonitor)
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                onCancel()
                return nil
            }
            let modifiers = event.modifierFlags.intersection(Shortcut.relevantModifiers)
            guard !modifiers.isEmpty, let key = Key(carbonKeyCode: UInt32(event.keyCode)) else { return nil }
            onRecord(Shortcut(key: key, modifiers: modifiers))
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Features

private struct FeatureSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var automationStatus: String?

    var body: some View {
        Form {
            Section("Screenshot") {
                FeatureEditor(
                    feature: $settings.screenshot,
                    placeholders: "{path}, {userText}",
                    manualHint: "The screenshot is attached to the input — send it yourself."
                )
            }

            Section("Website (Firefox / Zen)") {
                FeatureEditor(
                    feature: $settings.website,
                    placeholders: "{url}, {title}, {content}",
                    manualHint: "URL, title and page text are placed in the input — send them yourself."
                )
                if settings.website.useSystemPrompt {
                    ForEach($settings.websiteURLPromptOverrides) { $rule in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("URL pattern", text: $rule.pattern, prompt: Text("e.g. github.com"))
                                Button {
                                    settings.websiteURLPromptOverrides.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete rule")
                            }
                            TextEditor(text: $rule.prompt)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 50)
                        }
                    }
                    Button("Add URL rule") {
                        settings.websiteURLPromptOverrides.append(WebsiteURLPromptOverride())
                    }
                    Text("The first matching rule replaces the default prompt for that site.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("File (Finder / Preview)") {
                FeatureEditor(
                    feature: $settings.file,
                    placeholders: "{paths}, {path}, {filename}, {userText}",
                    manualHint: "The files are attached to the input — send them yourself."
                )
                Button("Request automation permission") {
                    automationStatus = FileContextService.requestPermissions()
                }
                if let automationStatus {
                    Text(automationStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FeatureEditor: View {
    @Binding var feature: FeatureSettings
    let placeholders: String
    let manualHint: String

    var body: some View {
        Toggle("Send automatically with a prompt", isOn: $feature.useSystemPrompt)
        if feature.useSystemPrompt {
            TextEditor(text: $feature.systemPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 64)
            Text("Placeholders: \(placeholders)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Open chat window when the answer arrives", isOn: $feature.openChatAfterSend)
            Toggle("Copy answer to clipboard", isOn: $feature.copyToClipboardAfterSend)
            Toggle("Read answer aloud", isOn: $feature.speakAfterSend)
        } else {
            Text(manualHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Speech

private struct SpeechSettings: View {
    @Bindable var settings: AppSettings
    let speech: SpeechService
    private let voices = SpeechService.selectableVoices

    var body: some View {
        Form {
            Section("Voice") {
                Picker("Voice", selection: $settings.speechVoiceIdentifier) {
                    Text("Automatic (best voice for the answer's language)").tag("")
                    Divider()
                    ForEach(voices, id: \.identifier) { voice in
                        Text("\(voice.name) — \(Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language) (\(SpeechService.qualityLabel(voice.quality)))")
                            .tag(voice.identifier)
                    }
                }

                LabeledContent("Speed") {
                    HStack {
                        Image(systemName: "tortoise").foregroundStyle(.secondary)
                        Slider(
                            value: $settings.speechRate,
                            in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate
                        )
                        Image(systemName: "hare").foregroundStyle(.secondary)
                    }
                }
                Button("Reset speed") { settings.speechRate = AVSpeechUtteranceDefaultSpeechRate }
                    .disabled(settings.speechRate == AVSpeechUtteranceDefaultSpeechRate)

                Picker("Read", selection: $settings.speechLength) {
                    Text("Whole answer").tag(SpeechLength.full)
                    Text("Only the first two sentences").tag(SpeechLength.short)
                }

                HStack {
                    Button(speech.isSpeaking ? "Stop" : "Preview") {
                        if speech.isSpeaking {
                            speech.stop()
                        } else {
                            speech.speak(markdown: previewText, length: .full)
                        }
                    }
                }
            }

            if let hint = qualityHint {
                Section {
                    Text(hint)
                        .font(.callout)
                    Button("Open Spoken Content Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } header: {
                    Label("Better voices available", systemImage: "info.circle")
                }
            }

            Section {
                Text("Code blocks, Markdown symbols and emoji are skipped; links are read as their site name. Use the speaker button below an answer to read it, or stop speech from the chat header or the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var previewLanguage: String {
        voices.first { $0.identifier == settings.speechVoiceIdentifier }?.language
            ?? AVSpeechSynthesisVoice.currentLanguageCode()
    }

    private var previewText: String {
        previewLanguage.hasPrefix("de")
            ? "Hallo! So klingt Claude Chat, wenn eine Antwort vorgelesen wird."
            : "Hello! This is how Claude Chat sounds when it reads an answer aloud."
    }

    /// Shown when only standard-quality voices are installed for the system language.
    private var qualityHint: String? {
        guard settings.speechVoiceIdentifier.isEmpty,
              let best = SpeechService.bestVoice(for: AVSpeechSynthesisVoice.currentLanguageCode()),
              best.quality == .default else { return nil }
        return "Only standard-quality voices are installed for your language. For much more natural speech, download an Enhanced or Premium voice: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices."
    }
}
