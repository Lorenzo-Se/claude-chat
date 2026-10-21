# Claude Chat

**A native macOS menu bar app with a floating chat window for Claude. It runs on your existing Claude subscription through the Claude Code CLI, with no API key and no API billing.**

Press a shortcut from anywhere to open the chat window and ask a question. You can also hand Claude a screenshot, the web page you are reading, or the file you have selected in Finder, each with a single key combination. Answers stream in live and can be read aloud.

- Native Swift app (AppKit + SwiftUI), 2 MB, no Dock icon, little memory while idle
- Uses the `claude` CLI you are already logged in to (`claude -p`, headless)
- Runs on macOS 14 Sonoma or later, Apple silicon and Intel

---

## Features

| | |
|---|---|
| 💬 **Floating chat** | Toggle it with a global shortcut. It always opens on the display and desktop you are working on, with the cursor in the input field. The window does not take focus away from the app you are in. |
| ⚡️ **Live answers** | Responses stream in as Claude writes them, with formatted Markdown: headings, lists, tables, and code blocks with a copy button. |
| 🗂 **Conversations** | Several conversations can run in parallel, each continuing its own Claude session. Rename or delete them by right-clicking in the sidebar. |
| 📸 **Screenshots** | Capture the full screen or drag out a region. The image is captured at native Retina resolution and sent to Claude. The chat window itself is never in the picture. |
| 🌐 **Web pages** | Sends the text of the active tab in Firefox or Zen, using a small companion extension. |
| 📄 **Files** | Sends the files selected in Finder or the document open in Preview. |
| 🔊 **Read aloud** | Reads answers aloud with the best voice installed for the answer's language. Code, Markdown symbols and emoji are skipped, and links are read as the site name. Voice, speed and length are adjustable. |
| 🤖 **Automatic prompts** | Screenshots, web pages and files can be sent with a prompt template you write. When the answer arrives, the app can open the chat, copy the answer, or read it aloud. Per-site prompt rules let you, for example, summarise YouTube pages differently from GitHub pages. |
| ⌨️ **Shortcuts** | Every shortcut can be changed, and the app warns about conflicts. Launch at login is optional. |

## Requirements

- **macOS 14** (Sonoma) or later
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** installed and logged in (`claude login`) with a Claude subscription
- **Firefox or Zen**, only needed for sending web pages

## Installation

1. Download `ClaudeChat-<version>.dmg` from the [latest release](https://github.com/Lorenzo-Se/claude-chat/releases/latest).
2. Open the DMG and drag **ClaudeChat.app** to **Applications**.
3. Start the app once. It is not notarized by Apple, so macOS blocks the first launch:
   - Open **System Settings → Privacy & Security** and click **Open Anyway** next to the message about Claude Chat, **or**
   - run `xattr -dr com.apple.quarantine /Applications/ClaudeChat.app` in Terminal once.
4. *Optional, for web pages:* in Firefox or Zen, open `about:addons` → ⚙︎ → **Install Add-on From File…** and choose the `.xpi` file from the DMG. Then restart the browser.

A chat bubble icon appears in the menu bar. Left-click it to open the chat; right-click it for the menu and **Settings…**.

> **Updating from 0.1.x:** your conversations and settings are kept. macOS asks once more for the Screen Recording and Automation permissions. The browser extension is unchanged.

## Keyboard shortcuts

| Action | Default |
|---|---|
| Show / hide chat | **⌃⌥⌘K** |
| Full-screen screenshot (display under the pointer) | **⌥⇧S** |
| Region screenshot | **⌥⇧D** |
| Send current web page | **⌥⇧W** |
| Send selected file(s) | **⌥⇧F** |
| New conversation | **⌥⇧N** |

Inside the chat window:

| Key | Action |
|---|---|
| **↩** | Send |
| **⇧↩** | New line |
| **⎋** | Hide window |
| **⌘A / ⌘C / ⌘V / ⌘X / ⌘Z** | Standard text editing |
| **⌘,** | Settings |

Change the global shortcuts in **Settings → Shortcuts**.

## Settings

- **General**: path to the Claude CLI (detected automatically through your login shell), model (CLI default, Sonnet, Opus or Haiku), live streaming, launch at login.
- **Shortcuts**: record new key combinations; conflicts are detected.
- **Features**: one section each for screenshots, web pages and files:
  - *Send automatically with a prompt*: the item is sent immediately with your template. Placeholders: `{path}`, `{url}`, `{title}`, `{content}`, `{paths}`, `{filename}`, `{userText}`.
  - *Off*: the item is attached to the input field so you can add your own question.
  - *After the answer*: open the chat, copy the answer to the clipboard, or read it aloud.
  - *Per-site rules* (web pages): the first matching pattern replaces the default prompt. A pattern can be `github.com`, `youtube.com/watch` or `https://docs.swift.org`.
- **Speech**: voice (automatic or a fixed one), speed, whole answer or the first two sentences, and a preview.

> 🔊 **Tip:** macOS ships with basic voices only. For far more natural speech, download an *Enhanced* or *Premium* voice under **System Settings → Accessibility → Spoken Content → System Voice → Manage Voices**. Claude Chat picks it up automatically.

## Permissions

macOS asks the first time you use a feature that needs a permission:

| Permission | Needed for |
|---|---|
| **Screen & System Audio Recording** | Screenshots. macOS requires a restart of the app after granting it. |
| **Automation → Finder / Preview** | Sending files |

Web pages need no macOS permission. The Firefox extension talks to the app through a local Native Messaging host, which the app installs in `~/.claudechat/`.

## Privacy and security

- Requests go only to Anthropic, through your local Claude Code CLI. The app has no telemetry and no server of its own.
- Conversations are stored as JSON files in `~/Library/Application Support/dev.claudechat/conversations/`.
- Screenshots and attached files are copied to `~/Library/Caches/dev.claudechat/` and deleted after 24 hours.
- ⚠️ **Claude runs with tools pre-approved.** It can read and write files and run shell commands in your home directory without asking, as it would in a trusted Claude Code session. Remember this when you send web pages or files from untrusted sources, because their content could try to instruct Claude.

## Troubleshooting

| Problem | Solution |
|---|---|
| "Claude CLI not found" | Run `which claude` in Terminal and enter that path under **Settings → General**. |
| "Claude CLI is not logged in" | Run `claude login` in Terminal. |
| Screenshot says permission is missing | Enable Claude Chat under **Privacy & Security → Screen & System Audio Recording**, then quit and restart the app. |
| "No connection to the browser" | Make sure Firefox or Zen is running with the extension enabled. Restart the browser after the first launch of the app. |
| "Not allowed to control Finder" | Enable Claude Chat under **Privacy & Security → Automation**. |
| Voice sounds robotic | Download an Enhanced or Premium voice (see the tip above). |

More help for the browser extension: [ClaudeChatExtension/README.md](ClaudeChatExtension/README.md).

## Building from source

Requires Xcode 16 or later (Swift 6 toolchain).

```bash
git clone https://github.com/Lorenzo-Se/claude-chat.git
cd claude-chat

swift test                       # unit and process tests
./scripts/build-app.sh           # release build, universal binary → build/Release/ClaudeChat.app
./scripts/build-app.sh debug     # debug build for this Mac        → build/Debug/ClaudeChat.app
./scripts/create-dmg.sh          # DMG with app + extension (needs the signed .xpi in build/Release)
```

- The app is signed with your first *Developer ID Application* identity if you have one, otherwise ad-hoc. Override with `CODE_SIGN_IDENTITY="…"`. With ad-hoc signing, macOS asks again for its permissions after every rebuild.
- `CLAUDE_CHAT_LIVE_TEST=1 swift test --filter Live` runs end-to-end tests against the real `claude` CLI. These use your subscription quota.
- To develop in Xcode, open `Package.swift`.
- Signing, notarization and signing the extension are covered in [docs/RELEASE.md](docs/RELEASE.md).

## How it works

```
 ┌──────────────── Claude Chat (menu bar app) ────────────────┐
 │  Floating panel (SwiftUI)    Global hotkeys    Settings    │
 │          │                                                 │
 │  ChatController — one request per conversation             │
 │          │                                                 │
 │  ClaudeRunner ── claude -p --output-format stream-json ──▶ Claude Code CLI ──▶ Anthropic
 │                  prompt via stdin, --resume <session>      │
 │                                                            │
 │  ScreenCaptureKit · AppleScript (Finder/Preview) · Speech  │
 └──────────────────────────────▲─────────────────────────────┘
                                │ Unix socket
        Firefox/Zen extension ──▶ Native Messaging host
```

Each message starts one `claude` process. Claude's session ID is stored with the conversation, so the next message continues that session with `--resume`.

```
Package.swift
Sources/
  ClaudeChatCore/        Testable logic: CLI process + stream protocol, persistence,
                         prompt templates, Markdown parsing, speech text
  ClaudeChat/            The app: panel, chat UI, settings, capture, files, speech
  ClaudeChatNativeHost/  Native Messaging host (browser ↔ app)
Tests/                   Swift Testing suites, including a fake `claude` CLI
ClaudeChatExtension/     Firefox/Zen WebExtension
Resources/               Info.plist, entitlements
scripts/                 Build, DMG and extension signing
```

## Known limitations

- Each message starts a fresh `claude` process, which adds roughly 1–2 s before the answer begins.
- A running request uses about 100–250 MB of RAM for the CLI process.
- Usage counts against the same quota as Claude Code in the terminal.
- Web pages can only be sent from Firefox and Zen, not from Safari or Chrome.
- The app is not available on the Mac App Store, because it starts subprocesses and uses Native Messaging.

## Further reading

- [SPEC.md](SPEC.md): original technical specification
- [docs/RELEASE.md](docs/RELEASE.md): signing, notarization and distribution
- [ClaudeChatExtension/README.md](ClaudeChatExtension/README.md): browser extension setup
