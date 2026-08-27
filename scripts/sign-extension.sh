#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT_DIR="$ROOT/ClaudeChatExtension"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/build/Release}"
ARTIFACTS_DIR="$OUTPUT_DIR/extension-artifacts"

if [[ -f "$ROOT/scripts/amo-credentials.env" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/amo-credentials.env"
fi

API_KEY="${WEB_EXT_API_KEY:-${AMO_JWT_ISSUER:-}}"
API_SECRET="${WEB_EXT_API_SECRET:-${AMO_JWT_SECRET:-}}"

VERSION="$(
  python3 -c "import json; print(json.load(open('$EXT_DIR/manifest.json'))['version'])"
)"
XPI_NAME="claude-chat-website-extractor-${VERSION}.xpi"
XPI_PATH="$OUTPUT_DIR/$XPI_NAME"

if [[ -z "$API_KEY" || -z "$API_SECRET" ]]; then
  cat >&2 <<'EOF'
Error: Mozilla AMO API credentials are missing.

1. Create an account: https://addons.mozilla.org/developers/
2. Create API credentials (JWT issuer + secret)
3. Create file: scripts/amo-credentials.env

   WEB_EXT_API_KEY=<issuer>
   WEB_EXT_API_SECRET=<secret>

Or set environment variables and run again.
EOF
  exit 1
fi

echo "==> Signing extension (Mozilla AMO, unlisted)"
rm -rf "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR" "$OUTPUT_DIR"

npx --yes web-ext@8 sign \
  --source-dir="$EXT_DIR" \
  --api-key="$API_KEY" \
  --api-secret="$API_SECRET" \
  --channel=unlisted \
  --artifacts-dir="$ARTIFACTS_DIR"

SIGNED_XPI="$(find "$ARTIFACTS_DIR" -name '*.xpi' -type f | head -1)"
if [[ -z "$SIGNED_XPI" || ! -f "$SIGNED_XPI" ]]; then
  echo "Error: No signed XPI found in $ARTIFACTS_DIR" >&2
  exit 1
fi

cp "$SIGNED_XPI" "$XPI_PATH"
echo "==> Signed XPI: $XPI_PATH"
