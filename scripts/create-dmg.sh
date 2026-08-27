#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Release/ClaudeChat.app}"
VERSION="${MARKETING_VERSION:-0.1.0}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/build/Release}"
DMG_NAME="ClaudeChat-${VERSION}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
STAGING="$OUTPUT_DIR/dmg-staging"
EXT_VERSION="$(
  python3 -c "import json; print(json.load(open('$ROOT/ClaudeChatExtension/manifest.json'))['version'])"
)"
XPI_NAME="claude-chat-website-extractor-${EXT_VERSION}.xpi"
XPI_PATH="$OUTPUT_DIR/$XPI_NAME"

if [[ ! -d "$APP" ]]; then
  echo "App nicht gefunden: $APP" >&2
  echo "Zuerst ausführen: ./scripts/build-release.sh" >&2
  exit 1
fi

if [[ ! -f "$XPI_PATH" ]]; then
  echo "Signierte XPI nicht gefunden: $XPI_PATH" >&2
  echo "Zuerst ausführen: ./scripts/sign-extension.sh" >&2
  exit 1
fi

write_install_notes() {
  cat >"$STAGING/Installation.txt" <<EOF
Claude Chat — Installation
==========================

1. Claude Chat.app nach Programme ziehen und einmal starten
   (registriert den Native-Messaging-Host für Firefox/Zen).

2. Firefox-Extension installieren:
   - Firefox oder Zen öffnen
   - about:addons aufrufen
   - Zahnrad → „Add-on aus Datei installieren…"
   - Datei wählen: $XPI_NAME

3. Browser neu starten (empfohlen).

4. Test: Beliebige Webseite öffnen, in Claude Chat ⌥⇧W drücken.

Extension-ID: claudechat@dev.local
Native Host: dev.claudechat
EOF
}

echo "==> DMG vorbereiten"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/ClaudeChat.app"
cp "$XPI_PATH" "$STAGING/$XPI_NAME"
write_install_notes
ln -s /Applications "$STAGING/Applications"

if command -v create-dmg >/dev/null 2>&1; then
  echo "==> create-dmg"
  create-dmg \
    --volname "Claude Chat" \
    --window-pos 200 120 \
    --window-size 660 420 \
    --icon-size 100 \
    --icon "ClaudeChat.app" 160 185 \
    --hide-extension "ClaudeChat.app" \
    --icon "$XPI_NAME" 330 185 \
    --hide-extension "$XPI_NAME" \
    --icon "Installation.txt" 500 185 \
    --hide-extension "Installation.txt" \
    --app-drop-link 500 300 \
    "$DMG_PATH" \
    "$STAGING"
else
  echo "==> hdiutil (create-dmg nicht installiert)"
  TEMP_DMG="$OUTPUT_DIR/temp.dmg"
  hdiutil create -volname "Claude Chat" -srcfolder "$STAGING" -ov -format UDRW "$TEMP_DMG"
  hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
  rm -f "$TEMP_DMG"
fi

rm -rf "$STAGING"
echo "==> DMG erstellt: $DMG_PATH"
