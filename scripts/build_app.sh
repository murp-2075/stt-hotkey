#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="stt-hotkey"
BIN_NAME="stt-hotkey"

cd "$ROOT_DIR"

swift build -c release

BIN_PATH="$ROOT_DIR/.build/release/$BIN_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Binary not found at $BIN_PATH" >&2
  exit 1
fi

APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp "$ROOT_DIR/app/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -f "$ROOT_DIR/.env" ]]; then
  cp "$ROOT_DIR/.env" "$APP_DIR/Contents/MacOS/.env"
  echo "Copied .env into app bundle."
fi

echo "Built app: $APP_DIR"

echo "Ad-hoc signing (recommended for TCC prompts)..."
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" || true
else
  echo "codesign not found; skipping signing"
fi
