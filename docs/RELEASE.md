# Claude Chat — Release & Distribution

## Release-Build

Universal Binary (arm64 + x86_64), optimiert für Größe:

- `DEAD_CODE_STRIPPING = YES`
- `SWIFT_COMPILATION_MODE = wholemodule`
- `SWIFT_OPTIMIZATION_LEVEL = -O`
- `COPY_PHASE_STRIP` / `STRIP_INSTALLED_PRODUCT`
- `DEBUG_INFORMATION_FORMAT = dwarf` (keine dSYM im Standard-Release — kleinere Artefakte; für Crash-Analyse optional `dwarf-with-dsym` setzen)

```bash
chmod +x scripts/build-release.sh scripts/create-dmg.sh
./scripts/build-release.sh
./scripts/create-dmg.sh
```

Ergebnis:

- App: `build/Release/ClaudeChat.app`
- DMG: `build/Release/ClaudeChat-0.1.0.dmg`

## Code Signing (Developer ID)

Manuell oder per Umgebungsvariablen beim Build:

```bash
export DEVELOPMENT_TEAM="XXXXXXXXXX"
export CODE_SIGN_IDENTITY="Developer ID Application: Ihr Name (TEAMID)"
./scripts/build-release.sh
```

Vollständige Signatur inkl. Native Host und eingebetteter Binaries:

```bash
APP=build/Release/ClaudeChat.app
codesign --force --options runtime --sign "$CODE_SIGN_IDENTITY" \
  "$APP/Contents/MacOS/ClaudeChatNativeHost"
codesign --force --options runtime --deep --sign "$CODE_SIGN_IDENTITY" \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
```

## Notarisierung (manuell — Credentials erforderlich)

Apple Developer Account, App-spezifisches Passwort oder API-Key nötig. Nicht voll automatisierbar ohne gespeicherte Secrets.

```bash
DMG=build/Release/ClaudeChat-0.1.0.dmg

# DMG signieren
codesign --force --sign "$CODE_SIGN_IDENTITY" "$DMG"

# Einreichen
xcrun notarytool submit "$DMG" \
  --apple-id "ihre@email.de" \
  --team-id "TEAMID" \
  --password "@keychain:AC_PASSWORD" \
  --wait

# Staple
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
```

Alternativ mit App Store Connect API-Key:

```bash
xcrun notarytool submit "$DMG" \
  --key ~/private_keys/AuthKey_XXXXX.p8 \
  --key-id "KEYID" \
  --issuer "ISSUER-UUID" \
  --wait
```

## Hardened Runtime

- `ENABLE_HARDENED_RUNTIME = YES` im Xcode-Target
- Kein App Sandbox (Subprozesse + Native Messaging)
- Verteilung nur notarisiert außerhalb des Mac App Store

## Einstellungen in der App

Menüleisten-Icon → Rechtsklick → **Einstellungen…** (oder ⌘, im Kontextmenü).
