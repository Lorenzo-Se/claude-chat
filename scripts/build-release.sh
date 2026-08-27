#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/ClaudeChat/ClaudeChat.xcodeproj"
SCHEME="ClaudeChat"
CONFIG="Release"
DERIVED="${DERIVED_DATA_PATH:-$ROOT/build/DerivedData}"
OUTPUT="${OUTPUT_DIR:-$ROOT/build/Release}"

echo "==> Release-Build (Universal Binary)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="arm64 x86_64" \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" \
  build

APP_PATH="$DERIVED/Build/Products/$CONFIG/ClaudeChat.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Fehler: $APP_PATH nicht gefunden" >&2
  exit 1
fi

mkdir -p "$OUTPUT"
rm -rf "$OUTPUT/ClaudeChat.app"
ditto "$APP_PATH" "$OUTPUT/ClaudeChat.app"

echo "==> Fertig: $OUTPUT/ClaudeChat.app"
file "$OUTPUT/ClaudeChat.app/Contents/MacOS/ClaudeChat" || true
