#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/build/Release}"

echo "==> 1/3 macOS App (Release)"
"$ROOT/scripts/build-release.sh"

echo "==> 2/3 Firefox-Extension (signiert)"
"$ROOT/scripts/sign-extension.sh"

echo "==> 3/3 DMG mit App + Extension"
"$ROOT/scripts/create-dmg.sh" "$OUTPUT_DIR/ClaudeChat.app"

echo ""
echo "Fertig:"
echo "  App:  $OUTPUT_DIR/ClaudeChat.app"
echo "  XPI:  $OUTPUT_DIR/claude-chat-website-extractor-"*.xpi
echo "  DMG:  $OUTPUT_DIR/ClaudeChat-"*.dmg
