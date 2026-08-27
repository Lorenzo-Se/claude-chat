#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/build/Release}"

echo "==> 1/3 macOS app (Release)"
"$ROOT/scripts/build-release.sh"

echo "==> 2/3 Firefox extension (signed)"
"$ROOT/scripts/sign-extension.sh"

echo "==> 3/3 DMG with app + extension"
"$ROOT/scripts/create-dmg.sh" "$OUTPUT_DIR/ClaudeChat.app"

echo ""
echo "Done:"
echo "  App:  $OUTPUT_DIR/ClaudeChat.app"
echo "  XPI:  $OUTPUT_DIR/claude-chat-website-extractor-"*.xpi
echo "  DMG:  $OUTPUT_DIR/ClaudeChat-"*.dmg
