# Claude Chat — Release & Distribution

## Release build

Universal binary (arm64 + x86_64) built with SwiftPM in release mode (`-O`, whole-module), local symbols stripped (`strip -x`). dSYMs stay in `.build/apple/Products/Release/` for crash analysis.

```bash
./scripts/build-app.sh
./scripts/create-dmg.sh
```

Output:

- App: `build/Release/ClaudeChat.app`
- DMG: `build/Release/ClaudeChat-<version>.dmg` (version from `Resources/Info.plist`)

## Code signing (Developer ID)

`scripts/build-app.sh` signs the native host and the app (hardened runtime, secure timestamp). It picks the first "Developer ID Application" identity automatically, or use:

```bash
export CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./scripts/build-app.sh
```

Verify:

```bash
APP=build/Release/ClaudeChat.app
codesign --verify --deep --strict --verbose=2 "$APP"
```

## Notarization (manual — credentials required)

Apple Developer account, app-specific password, or API key required. Cannot be fully automated without stored secrets.

```bash
DMG=build/Release/ClaudeChat-0.1.0.dmg

# Sign DMG
codesign --force --sign "$CODE_SIGN_IDENTITY" "$DMG"

# Submit
xcrun notarytool submit "$DMG" \
  --apple-id "you@email.com" \
  --team-id "TEAMID" \
  --password "@keychain:AC_PASSWORD" \
  --wait

# Staple
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
```

Alternatively with App Store Connect API key:

```bash
xcrun notarytool submit "$DMG" \
  --key ~/private_keys/AuthKey_XXXXX.p8 \
  --key-id "KEYID" \
  --issuer "ISSUER-UUID" \
  --wait
```

## Hardened Runtime

- `scripts/build-app.sh` signs app and native host with `--options runtime` and `Resources/ClaudeChat.entitlements`
- No App Sandbox (subprocesses + Native Messaging)
- Distribution only notarized outside the Mac App Store

## In-app settings

Menu bar icon → right-click → **Settings…** (or ⌘, from the context menu).
