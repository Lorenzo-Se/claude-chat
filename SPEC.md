# Technical Specification: Floating Claude Chatbot for macOS

**Purpose of this document:** Complete technical foundation so that an AI (e.g. Claude Code) can implement this app independently without needing to ask questions about fundamental architecture decisions. Open items are explicitly marked at the end.

---

## 1. Project Overview

Native macOS desktop app (Swift/SwiftUI + AppKit) that works as a **floating, globally shortcut-invokable chat window** and uses **Claude Code in headless mode** (`claude -p`) as the backend — authenticated via the user's existing Claude subscription, not via API billing.

### Core Features
1. Floating chat window, show/hide via global shortcut
2. Capture screenshot (full screen or region selection) via shortcut and send to the AI
3. Extract content from the currently open website and send to the AI
4. Display responses from Claude Code (text, Markdown, code if applicable) in the chat window

### Non-Functional Requirements
- Smallest possible binary/installation size
- Lowest possible RAM usage **at idle** (the app runs permanently in the background/menu bar)
- No Dock icon, no unnecessary chrome — pure utility app
- No separate API billing — usage exclusively via the locally logged-in Claude Code CLI subscription

> **Important note on expectations:** The idle RAM of the app itself can be very low (Swift/AppKit, no Electron base). However, while a chat request is active, a separate Node.js process (`claude` CLI) inevitably starts with typically 100–250 MB RAM for the duration of the request. This is the cost of the architecture decision "subscription instead of API" and should not be misunderstood as a bug.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  macOS Menu Bar App (LSUIElement, no Dock icon)        │
│                                                           │
│  ┌───────────────┐   ┌────────────────┐  ┌────────────┐ │
│  │ Global Hotkey  │   │ Floating       │  │ Settings   │ │
│  │ Manager        │──▶│ NSPanel + UI   │  │ Window     │ │
│  └───────────────┘   └───────┬────────┘  └────────────┘ │
│                               │                          │
│         ┌─────────────────────┼─────────────────────┐    │
│         ▼                     ▼                     ▼    │
│  ┌─────────────┐     ┌────────────────┐   ┌──────────────┐│
│  │ Screen /     │     │ Claude Code     │   │ Website-     ││
│  │ Region       │     │ Process Manager │   │ Content-     ││
│  │ Capture      │     │ (Process API)   │   │ Extractor    ││
│  │ (ScreenCap-  │     │                 │   │ (AppleScript ││
│  │ tureKit)     │     │                 │   │ or WebExt.)  ││
│  └─────────────┘     └────────┬────────┘   └──────────────┘│
│                                │                            │
│                                ▼                            │
│                      subprocess: `claude -p ...`             │
│                      (uses existing `claude login`             │
│                       session of the user)                    │
└─────────────────────────────────────────────────────────┘
```

---

## 3. Core Components in Detail

### 3.1 Floating Window

- Implementation: `NSPanel` subclass (not a regular `NSWindow`), so the window does not steal focus/activation state from other apps.
- `styleMask`: `[.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView]`
- `level`: `.floating` (default) — optionally `.statusBar` if the window should also be visible over full-screen apps
- `collectionBehavior`: `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` — so the window is available on every virtual desktop
- `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`
- Appearance: `NSVisualEffectView` as background (material `.hudWindow` or `.sidebar`), rounded corners, subtle shadow
- Size: default e.g. 420×600pt, resizable, position/size persisted via `setFrameAutosaveName`
- Show/hide: fade animation via `NSAnimationContext`, no hard show/hide
- Closing the window does NOT quit the app — only `orderOut`, app continues running in the background

### 3.2 Global Shortcut Manager

- **Recommendation:** Do not implement Carbon `RegisterEventHotKey` by hand; instead use the established, very small SPM package **`HotKey`** (soffes/HotKey) — wraps Carbon internally, minimal footprint, actively used in many utility apps.
- Does **not** require Accessibility permission for simple global key combinations.
- Default shortcuts (all freely configurable in Settings, stored as `KeyCombo` in `UserDefaults`):

| Action | Default Shortcut |
|---|---|
| Show/hide chat window | ⌥⌘Space |
| Capture full screen & send | ⌥⇧S |
| Capture region & send | ⌥⇧D |
| Extract current website & send | ⌥⇧W |
| New conversation | ⌥⇧N |

### 3.3 Claude Code Headless Integration (Core Component)

**Prerequisite (app checks this but does not implement it itself):**
The user must have the Claude Code CLI installed and authenticated once via `claude login` with their subscription. The app detects missing auth through a test call and then shows an onboarding guide ("Please run `claude login` in the terminal").

**CLI path resolution:**
- Do not hardcode (`/usr/local/bin/claude` is not guaranteed, especially with nvm/Homebrew installations).
- On first launch: run `Process` with `/bin/zsh -l -c "which claude"` (login shell so PATH including nvm/Homebrew is loaded), cache path in `UserDefaults`.
- In Settings: manual override path possible if auto-detection fails.

**Command pattern per chat message:**
```bash
claude -p "<prompt text>" \
  --output-format stream-json \
  --verbose \
  --include-partial-messages \
  [--resume <session_id>] \
  --allowedTools "Read" \
  --permission-mode acceptEdits \
  [--model sonnet|opus|haiku]
```

- **Streaming (recommended for UX):** `--output-format stream-json` delivers newline-delimited JSON events that are parsed incrementally and update the last chat bubble live (similar to ChatGPT streaming effect).
- **Simpler/more robust fallback:** `--output-format json` (blocking), response comes as a single JSON object with fields including `result`, `session_id`, `total_cost_usd`, `duration_ms`.

**Session management (mandatory, otherwise no chat memory):**
- `claude -p` is stateless per invocation from the calling process's perspective.
- First message of a conversation: **without** `--resume`. From the JSON response, `session_id` is extracted and associated locally with the conversation.
- Each follow-up message: **with** `--resume <session_id>`.
- "New conversation" action: deletes the associated `session_id`, next message starts again without `--resume`.
- Data model (see 3.7) stores: `conversationId (UUID, local)` ↔ `claudeSessionId (String, from CLI)`.

**Process management:**
- Each invocation runs asynchronously via `Process` + `Pipe` (stdout/stderr), never blocking on the main thread.
- Timeout: automatically terminate process after e.g. 120s (`process.terminate()`), display error in UI.
- User cancellation: "Stop" button in UI calls `process.terminate()` on the running process.
- Only one active process per conversation at a time (avoid race conditions with `session_id`). Multiple parallel conversations with their own process each are possible, but optional/later.

**Error handling:**
- Exit code ≠ 0 or `is_error: true` in JSON → display error message in chat as system message, including stderr excerpt.
- CLI not found → onboarding hint.
- Not logged in → onboarding hint with link/guide to `claude login`.

### 3.4 Screenshot Capture (Full Screen & Region)

- **API:** `ScreenCaptureKit` (not the deprecated `CGWindowListCreateImage`) — more efficient, intended by Apple for new capture apps.
- **Full screen:** `SCScreenshotManager.captureImage(contentFilter:configuration:)` — single capture, no permanent capture stream needed → minimal RAM/CPU overhead compared to `SCStream`. Usable since minimum target is macOS 14+ (see decision below).
- **Region selection:** custom transparent, borderless overlay window over all displays, user drags a rectangle (similar to ⌘⇧4), then the full-screen result from `SCScreenshotManager` is cropped to the selected region (`CGImage.cropping(to:)`).
- **Permission:** Screen Recording TCC permission. Check via `CGPreflightScreenCaptureAccess()`, request via `CGRequestScreenCaptureAccess()`. If denied: show guide to System Settings → Privacy & Security → Screen Recording. **Important:** macOS requires an app restart after granting the permission.
- **Storage:** Screenshot as PNG in `~/Library/Caches/<BundleID>/screenshots/`, filename with timestamp/UUID.
- **Cleanup:** On app launch, delete all screenshot files older than 24h.
- **Handoff to Claude Code:** File path is embedded in the prompt, e.g.:
  ```
  claude -p "Analyze this screenshot: /Users/.../screenshots/abc.png" --allowedTools "Read"
  ```
  ⚠️ **To verify (see Section 6):** The exact syntax of how Claude Code CLI recognizes image paths in a prompt in headless mode and reads them via its `Read` tool is not documented with certainty and should be empirically tested by the building AI at the start (simple test call with a test image).

### 3.5 Website Content Extraction

Two possible routes with very different effort — **browser priority must be clarified before implementation** (see Section 6):

**Route A — AppleScript (Safari & Chromium browsers only: Chrome, Edge, Brave, Arc, etc.)**
- Significantly simpler, no extension code needed.
- Safari example:
  ```applescript
  tell application "Safari"
    set theURL to URL of front document
    set theText to do JavaScript "document.body.innerText" in front document
  end tell
  ```
- Execution from Swift via `NSAppleScript` or `osascript` as subprocess.
- First execution automatically triggers a macOS automation permission request ("App wants to control Safari").
- For Chrome analogously via `tell application "Google Chrome" ... execute front window's active tab javascript "..."`.

**Route B — WebExtension + Native Messaging (required for Firefox-based browsers: Firefox, Zen)**
Firefox-based browsers do not support AppleScript control. Required components:
1. **WebExtension** (Manifest V2/V3): Content script extracts `document.title`, `document.URL`, and cleaned reading text (simple heuristic or Readability.js port to remove nav/footer/ads).
2. **Background script** of the extension listens for incoming native messaging messages and requests the content script extraction from the active tab.
3. **Native Messaging Host**: small helper executable, registered via manifest JSON in `~/Library/Application Support/Mozilla/NativeMessagingHosts/`. Communicates with the extension via the length-prefixed JSON protocol prescribed by Firefox on stdin/stdout, forwards requests/responses to the main app (e.g. via a local Unix domain socket).
4. **Flow on shortcut press:** Main app → socket request to native messaging host → host → extension background script → content script in active tab → extracted text back through the same chain → main app builds the Claude Code prompt from it.
5. Significantly more implementation effort than Route A (own extension signing/distribution, host installation, protocol handling).

**Decision:** Route B (Firefox/Zen, WebExtension + Native Messaging) is the priority and will be implemented directly — Route A (Safari/Chrome) is not in scope unless explicitly requested later.

### 3.6 Chat UI

- SwiftUI view inside the `NSPanel` (embedded via `NSHostingView`).
- Markdown rendering: native `AttributedString(markdown:)` (no external Markdown package needed → keeps the app small).
- Message list: `LazyVStack` in `ScrollView` + `ScrollViewReader` for auto-scroll.
- Streaming: last assistant bubble is updated live on `stream-json` events.
- Input field: multi-line, ⌘⏎ or ⏎ to send (configurable), screenshot thumbnail preview before sending if an image is attached.
- Code blocks: custom presentation with copy button and monospace font.
- **Conversation list (due to multiple conversations, see 3.7):** compact sidebar or expandable popover with title + timestamp per conversation, "+" button for new conversation, swipe/right-click to delete/rename. Active loading state (spinner) per entry if a `claude` process is running there.

### 3.7 Conversation & Session Storage

- Deliberately **no** Core Data/SwiftData runtime to keep overhead/size small — instead simple JSON files in `~/Library/Application Support/<BundleID>/conversations/`, one file per conversation (e.g. `<conversationId>.json`).
- Data model per conversation:
  ```json
  {
    "id": "uuid",
    "title": "Auto or user-renamed",
    "createdAt": "ISO8601",
    "claudeSessionId": "string or null",
    "messages": [
      { "role": "user|assistant|system", "content": "...", "timestamp": "...", "attachmentPath": "optional" }
    ]
  }
  ```
- **Decision: Multiple parallel conversations from the start (v1).** This additionally means:
  - A sidebar or dropdown/popover for conversation overview and switching in the UI (3.6).
  - An index file (e.g. `conversations/index.json`) with a list of all conversation IDs, titles, and `updatedAt` for fast loading of the overview without having to parse all conversation files individually.
  - One independent `claude` process per conversation possible — the process queue in 3.3 still applies only **per conversation** (max. one active request per conversation at a time), not globally for the app.
  - UI must clearly indicate which conversation currently has a running request (e.g. spinner next to the conversation title in the list), since multiple can be "typing" simultaneously.

### 3.8 Settings

- Shortcut customization (recorder UI, e.g. via the `HotKey` package or a custom minimal implementation)
- Claude CLI path override
- Model selection (`--model sonnet|opus|haiku`)
- Streaming on/off
- "Launch at login" via `SMAppService` (macOS 13+)
- Menu bar icon as primary presence (`NSStatusItem`); app runs as accessory app (`LSUIElement = true` in Info.plist) → **no Dock icon**, reduces impression of bloat and fits the "lean" goal

### 3.9 Permissions (Overview)

| Permission | Purpose | When Requested |
|---|---|---|
| Screen Recording | Screenshot feature | On first screenshot attempt |
| Automation (Safari/Chrome) | AppleScript website extraction (Route A) | On first extraction attempt per browser |
| No Accessibility needed | for simple global hotkeys via `HotKey` package | — |
| No Full Disk Access needed | — | — |

### 3.10 Data Storage & Cleanup

- Screenshots: `~/Library/Caches/<BundleID>/screenshots/`, automatic deletion >24h on app launch
- Conversations: see 3.7
- No telemetry/analytics (keeps app small, protects privacy)

---

## 4. Technology Decisions at a Glance

| Area | Decision | Rationale |
|---|---|---|
| UI framework | SwiftUI in `NSPanel`/`NSHostingView` | Native, small, no Electron overhead |
| Backend | Claude Code CLI headless (`claude -p`) | Uses existing subscription instead of API billing |
| Global hotkeys | `HotKey` SPM package (Carbon wrapper) | Proven, minimal, no Accessibility permission needed |
| Screenshot API | `ScreenCaptureKit` / `SCScreenshotManager` | Modern, efficient Apple API instead of deprecated APIs |
| Persistence | Flat JSON files | Avoids Core Data/SwiftData runtime overhead |
| Markdown rendering | Native `AttributedString(markdown:)` | No external dependency |
| App type | Accessory app (`LSUIElement`), menu bar instead of Dock | Fits utility character, saves resources |
| Distribution | Notarized outside Mac App Store | App Store sandbox prevents subprocess execution & native messaging |

---

## 5. Known Trade-offs / Limitations

1. **Latency per message:** Each `claude -p` invocation starts a new Node process → noticeable cold start (~1–2s) in addition to actual model response time. This is inherent to the chosen architecture (subscription instead of direct API) and cannot be eliminated through app optimization.
2. **RAM during active use:** ~100–250 MB per running `claude` process, released after completion. Idle state of the app itself remains low.
3. **Shared usage quota:** Headless invocations consume the same subscription quota as interactive Claude Code usage in the terminal — with intensive chat usage via the app, the quota can be exhausted faster.
4. **No Mac App Store distribution possible** due to the subprocess/native messaging architecture.
5. **Route B (Firefox/Zen extraction)** is a standalone mini-project (WebExtension + Native Messaging Host) with significantly more effort than Route A (AppleScript for Safari/Chrome).

---

## 6. Decisions Made & Remaining Open Question

**Decided:**
- Browser priority: **Firefox/Zen via Route B** (WebExtension + Native Messaging) — not Safari/Chrome.
- Minimum macOS version: **14+** (enables `SCScreenshotManager` and `SMAppService` without fallback code).
- Conversation model: **multiple parallel conversations from the start** (see 3.7, 3.6).

**Still open:**
1. **Image attachments in `claude -p`:** Exact syntax/behavior when referencing an image file in the headless prompt should be verified at the start of implementation with a simple test call before the screenshot feature code builds on it.

---

## 7. Proposed Phased Plan

**Phase 1 — MVP**
Floating `NSPanel` + global toggle shortcut + simple text chat via `claude -p` (blocking JSON, no streaming) + session handling (`--resume`) + simple JSON file storage. No screenshot, no website extraction.

**Phase 2 — Screenshots**
`ScreenCaptureKit` integration for full screen & region selection, attaching to prompt, permission flow.

**Phase 3 — Streaming**
Switch to `stream-json` for live response display.

**Phase 4 — Website Extraction**
Route B (WebExtension + Native Messaging Host for Firefox/Zen): first the native messaging host including installation/registration logic, then the WebExtension (content script + background script), finally the socket connection to the main app.

**Phase 5 — Polish & Distribution**
Settings UI, shortcut customization, launch at login, code signing, notarization, DMG creation, binary size optimization (dead code stripping, whole-module optimization).

---

## 8. Packaging & Distribution

- Universal Binary (arm64 + x86_64) via Xcode target "Any Mac"
- Release build: dead code stripping enabled, whole-module optimization (`-O`), debug symbols removed
- No App Sandbox (incompatible with subprocess execution & native messaging) — instead Hardened Runtime + notarization for distribution outside the App Store
- Distribution as notarized `.app` in a `.dmg`, e.g. via own website or GitHub Releases
