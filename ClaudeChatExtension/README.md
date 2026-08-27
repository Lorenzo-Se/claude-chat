# Claude Chat – Firefox/Zen Extension

This WebExtension extracts the content of the active browser tab for the Claude Chat macOS app (Route B: Native Messaging).

## Requirements

1. Claude Chat app installed and launched at least once (registers the Native Messaging host automatically).
2. Firefox or Zen Browser.

## Load the extension (developer mode)

### Firefox

1. Open `about:debugging#/runtime/this-firefox`
2. **Load Temporary Add-on…**
3. Select the `ClaudeChatExtension` folder (containing `manifest.json`)

### Zen Browser

1. Open `about:debugging`
2. **Load Temporary Add-on…**
3. Select the `ClaudeChatExtension` folder

After loading, the extension connects automatically to the Native Messaging host (`dev.claudechat`).

## Native Messaging

- Host name: `dev.claudechat`
- Extension ID: `claudechat@dev.local` (fixed in `manifest.json` → `browser_specific_settings.gecko.id`)
- Host manifest: `~/Library/Application Support/Mozilla/NativeMessagingHosts/dev.claudechat.json`
- Zen (if present): `~/Library/Application Support/Zen/NativeMessagingHosts/dev.claudechat.json`

Firefox expects **`allowed_extensions`** (extension ID) in the host manifest, not Chrome-style `allowed_origins` (`moz-extension://…`).

The app copies the host binary to:

`~/.claudechat/ClaudeChatNativeHost`

(Socket: `~/.claudechat/claudechat.sock`)

## Usage

1. Keep Firefox/Zen open with the extension loaded
2. Open any web page in the active tab
3. Press **⌥⇧W** in Claude Chat

The app extracts the title, URL, and cleaned text and sends them to Claude.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "No connection to browser" | Load the extension, restart the app (rewrites host manifest), restart the browser |
| "This extension does not have permission…" | Check host manifest: `allowed_extensions` must contain `["claudechat@dev.local"]` |
| Native Messaging blocked | In `about:config`, check whether extensions are allowed to use Native Messaging |
| Empty content | Wait for the page to finish loading; `about:` / `moz-extension:` pages are not supported |

### Check the console in about:debugging

1. Find the extension under **Temporary Extensions**
2. Click **Inspect** → open the console
3. Expected messages after loading:
   - `Claude Chat: Extension started. runtime.id: claudechat@dev.local origin: moz-extension://claudechat@dev.local/ …`
   - `Claude Chat: Native host connected. …`
4. On errors:
   - `connectNative failed: …` → check host manifest or app installation
   - `Native host disconnected: Access denied` → `allowed_extensions` does not match `runtime.id`

### Check host manifest manually

```bash
cat ~/Library/Application\ Support/Mozilla/NativeMessagingHosts/dev.claudechat.json
```

Expected (adjust path):

```json
{
  "allowed_extensions": ["claudechat@dev.local"],
  "description": "Claude Chat Native Messaging Host",
  "name": "dev.claudechat",
  "path": "/Users/<user>/.claudechat/ClaudeChatNativeHost",
  "type": "stdio"
}
```

## Manual tests

1. Build and launch the app → verify host manifest (see above)
2. Load the extension, open the console in `about:debugging` → `Native host connected` should appear
3. Open a web page, press **⌥⇧W** → chat panel shows extracted content
