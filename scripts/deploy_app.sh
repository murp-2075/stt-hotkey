#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="stt-hotkey"

cd "$ROOT_DIR"

pkill "$APP_NAME" >/dev/null 2>&1 || true

./scripts/build_app.sh

rm -rf "/Applications/${APP_NAME}.app"
cp -R "$ROOT_DIR/build/${APP_NAME}.app" "/Applications/"

open "/Applications/${APP_NAME}.app"
