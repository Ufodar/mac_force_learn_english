#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacForceLearnEnglish"
DIST_DIR="$ROOT_DIR/dist"
BUILD_APP="$ROOT_DIR/build/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"

mkdir -p "$DIST_DIR"

if [[ ! -d "$BUILD_APP" ]]; then
  echo "[dmg] missing app: $BUILD_APP" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cp -R "$BUILD_APP" "$TMP_DIR/$APP_NAME.app"
ln -s /Applications "$TMP_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$TMP_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null

echo "[dmg] done: $DMG_PATH"

