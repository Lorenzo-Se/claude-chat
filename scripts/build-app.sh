#!/usr/bin/env bash
# Builds ClaudeChat.app from the Swift package.
#   ./scripts/build-app.sh            release, universal (arm64 + x86_64) → build/Release/ClaudeChat.app
#   ./scripts/build-app.sh debug      debug, native arch                 → build/Debug/ClaudeChat.app
# Env: CODE_SIGN_IDENTITY (default: first "Developer ID Application" identity, else ad-hoc "-"),
#      MARKETING_VERSION (overrides CFBundleShortVersionString), OUTPUT_DIR.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
case "$CONFIG" in
  release) ARCH_FLAGS=(--arch arm64 --arch x86_64); OUTPUT="${OUTPUT_DIR:-$ROOT/build/Release}" ;;
  debug)   ARCH_FLAGS=(); OUTPUT="${OUTPUT_DIR:-$ROOT/build/Debug}" ;;
  *) echo "Usage: $0 [release|debug]" >&2; exit 1 ;;
esac

cd "$ROOT"
echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product ClaudeChat
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product ClaudeChatNativeHost
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="$OUTPUT/ClaudeChat.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClaudeChat" "$APP/Contents/MacOS/ClaudeChat"
cp "$BIN_DIR/ClaudeChatNativeHost" "$APP/Contents/MacOS/ClaudeChatNativeHost"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -n "${MARKETING_VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$APP/Contents/Info.plist"
fi
if [[ "$CONFIG" == release ]]; then
  strip -x "$APP/Contents/MacOS/ClaudeChat" "$APP/Contents/MacOS/ClaudeChatNativeHost"
fi

# Developer ID (distribution) if available, else ad-hoc. "Apple Development" identities are not used by
# default: without a provisioning profile AMFI rejects them and macOS moves the app to the Trash.
# Note: ad-hoc signatures change with every build, so macOS asks again for screen recording / automation.
IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)"
  IDENTITY="${IDENTITY:--}"
fi
echo "==> Signing with: $IDENTITY"
TIMESTAMP=(); [[ "$IDENTITY" == "Developer ID"* ]] && TIMESTAMP=(--timestamp)
codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --sign "$IDENTITY" \
  "$APP/Contents/MacOS/ClaudeChatNativeHost"
codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --sign "$IDENTITY" \
  --entitlements "$ROOT/Resources/ClaudeChat.entitlements" "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP"
file "$APP/Contents/MacOS/ClaudeChat"
