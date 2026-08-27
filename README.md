# Claude Chat

Native macOS menu bar app with a floating chat window that uses **Claude Code** in headless mode (`claude -p`) as its backend — authenticated via your existing Claude subscription, not API billing.

The app runs permanently in the background (no Dock icon), can be shown and hidden via a global shortcut, and supports screenshots, website extraction from Firefox/Zen, and sending files from Finder and Preview.

## Features

- **Floating chat window** — toggle via shortcut, visible on all desktops
- **Claude Code integration** — uses your locally logged-in CLI session (`claude login`)
- **Streaming responses** — live display while Claude is replying
- **Multiple conversations** — parallel chats with session management (`--resume`)
- **Screenshots** — full screen or region selection, sent directly to Claude
- **Website extraction** — content from the active Firefox/Zen tab via WebExtension + Native Messaging
- **Send files** — selected Finder files or open Preview documents
- **Customizable shortcuts** — all hotkeys configurable in Settings
- **Launch at login** — optional via Settings

## Requirements

| Requirement | Details |
|---|---|
| **macOS** | 14.0 (Sonoma) or later |
| **Claude Code CLI** | Installed and authenticated with `claude login` |
| **Firefox or Zen** | Website extraction only (WebExtension required) |
| **Xcode** | Building from source only (15+) |

## Installation

### Pre-built DMG

1. Open `ClaudeChat-0.1.0.dmg`
2. Drag **Claude Chat.app** to **Applications** and launch it once
3. Install the Firefox extension: `about:addons` → gear icon → **Install Add-on From File…** → select `claude-chat-website-extractor-1.0.0.xpi` from the DMG
4. Restart the browser (recommended)

On first launch, the app automatically registers the Native Messaging host for Firefox/Zen.

### Build from source

```bash
# Build the app
./scripts/build-release.sh

# Full release (app + signed extension + DMG)
./scripts/build-distribution.sh
```

Details on code signing and notarization: [docs/RELEASE.md](docs/RELEASE.md)

## Getting started

1. **Set up the Claude Code CLI** (if not already done):

   ```bash
   # Installation depends on your setup, e.g.:
   npm install -g @anthropic-ai/claude-code
   claude login
   ```

2. **Launch Claude Chat** — appears as an icon in the menu bar
3. **Open the chat** with the default shortcut **⌃⌥⌘K** (or left-click the menu bar icon)
4. **For website extraction:** install the Firefox extension (see above)

If the CLI is missing or you are not logged in, the app shows an onboarding guide.

## Keyboard shortcuts

All shortcuts can be customized in **Settings…** (menu bar icon → right-click).

| Action | Default |
|---|---|
| Toggle chat | ⌃⌥⌘K |
| Full-screen screenshot | ⌥⇧S |
| Region screenshot | ⌥⇧D |
| Extract website | ⌥⇧W |
| Send file | ⌥⇧F |
| New conversation | ⌥⇧N |

## Permissions

The app requests permissions only when you first use the corresponding feature:

| Permission | Purpose |
|---|---|
| **Screen Recording** | Screenshot feature |
| **Automation (Finder/Preview)** | Send file |
| **Native Messaging** | Website extraction via Firefox/Zen |

After granting Screen Recording permission, an **app restart** is required.

## Firefox extension

The WebExtension extracts the title, URL, and cleaned text of the active tab and forwards it to the app via a Native Messaging host.

- Detailed setup and troubleshooting: [ClaudeChatExtension/README.md](ClaudeChatExtension/README.md)
- For development, the extension can also be loaded temporarily via `about:debugging`

## Project structure

```
claude-chat/
├── ClaudeChat/              # macOS app (Swift/SwiftUI + AppKit)
│   └── ClaudeChat/
│       ├── Services/        # CLI, screenshots, conversations, hotkeys, …
│       ├── Views/           # Chat UI, settings
│       └── Windows/         # Floating NSPanel
├── ClaudeChatExtension/     # Firefox/Zen WebExtension
├── ClaudeChatNativeHost/    # Native Messaging host (stdin/stdout ↔ Unix socket)
├── scripts/                 # Build, signing, and DMG scripts
├── docs/                    # Release documentation
└── SPEC.md                  # Technical specification
```

## Architecture

```
Menu bar app (LSUIElement)
    ├── Floating NSPanel + SwiftUI chat
    ├── Global hotkeys (HotKey SPM)
    ├── ScreenCaptureKit (screenshots)
    ├── AppleScript (Finder/Preview)
    └── Claude Code CLI (claude -p, stream-json)
            ↑
Firefox/Zen extension → Native Messaging host → Unix socket
```

The app spawns a `claude` subprocess for each message and manages sessions via `--resume`. Conversations are stored as JSON files in `~/Library/Application Support/`.

## Development

```bash
# Release build
./scripts/build-release.sh

# DMG only (app must already exist)
./scripts/create-dmg.sh

# Sign extension (requires Mozilla AMO API keys in scripts/amo-credentials.env)
./scripts/sign-extension.sh
```

Open `ClaudeChat/ClaudeChat.xcodeproj` in Xcode for local development with debugging.

## Known limitations

- Each message starts a new `claude` process (~1–2 s cold start on top of response time)
- During active requests: ~100–250 MB RAM per running CLI process
- Usage counts against the same subscription quota as Claude Code in the terminal
- Not available on the Mac App Store (subprocesses and Native Messaging require distribution outside the store)
- Website extraction currently supports Firefox/Zen only, not Safari/Chrome

## License

See the repository for license information.

## Further reading

- [SPEC.md](SPEC.md) — full technical specification
- [docs/RELEASE.md](docs/RELEASE.md) — code signing, notarization, distribution
- [ClaudeChatExtension/README.md](ClaudeChatExtension/README.md) — extension setup and troubleshooting
