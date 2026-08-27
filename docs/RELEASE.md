# Claude Chat — Release & Distribution

## Release build

Universal binary (arm64 + x86_64), optimized for size:

- `DEAD_CODE_STRIPPING = YES`
- `SWIFT_COMPILATION_MODE = wholemodule`
- `SWIFT_OPTIMIZATION_LEVEL = -O`
- `COPY_PHASE_STRIP` / `STRIP_INSTALLED_PRODUCT`
- `DEBUG_INFORMATION_FORMAT = dwarf` (no dSYM in the default release — smaller artifacts; set `dwarf-with-dsym` optionally for crash analysis)

```bash
chmod +x scripts/build-release.sh scripts/create-dmg.sh
./scripts/build-release.sh
./scripts/create-dmg.sh
```

Output:

- App: `build/Release/ClaudeChat.app`
- DMG: `build/Release/ClaudeChat-0.1.0.dmg`

## Code signing (Developer ID)

Manually or via environment variables during build:

```bash
export DEVELOPMENT_TEAM="XXXXXXXXXX"
export CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./scripts/build-release.sh
```

Full signature including native host and embedded binaries:

```bash
APP=build/Release/ClaudeChat.app
codesign --force --options runtime --sign "$CODE_SIGN_IDENTITY" \
  "$APP/Contents/MacOS/ClaudeChatNativeHost"
codesign --force --options runtime --deep --sign "$CODE_SIGN_IDENTITY" \
  "$APP"
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

- `ENABLE_HARDENED_RUNTIME = YES` in the Xcode target
- No App Sandbox (subprocesses + Native Messaging)
- Distribution only notarized outside the Mac App Store

## In-app settings

Menu bar icon → right-click → **Settings…** (or ⌘, from the context menu).
