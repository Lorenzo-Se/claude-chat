#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Release/ClaudeChat.app}"
VERSION="${MARKETING_VERSION:-0.1.0}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/build/Release}"
DMG_NAME="ClaudeChat-${VERSION}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
STAGING="$OUTPUT_DIR/dmg-staging"

if [[ ! -d "$APP" ]]; then
  echo "App nicht gefunden: $APP" >&2
  echo "Zuerst ausführen: ./scripts/build-release.sh" >&2
  exit 1
fi

echo "==> DMG vorbereiten"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/ClaudeChat.app"
ln -s /Applications "$STAGING/Applications"

if command -v create-dmg >/dev/null 2>&1; then
  echo "==> create-dmg"
  create-dmg \
    --volname "Claude Chat" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "ClaudeChat.app" 150 185 \
    --hide-extension "ClaudeChat.app" \
    --app-drop-link 450 185 \
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
