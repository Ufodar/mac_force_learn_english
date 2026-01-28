#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="MacForceLearnEnglish"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CACHE_DIR="$BUILD_DIR/module-cache"

mkdir -p "$BUILD_DIR"
mkdir -p "$CACHE_DIR"

echo "[build] compiling..."
swiftc \
  -parse-as-library \
  -module-cache-path "$CACHE_DIR" \
  -Xcc -fmodules-cache-path="$CACHE_DIR" \
  -O \
  -framework Cocoa \
  -o "$BUILD_DIR/$APP_NAME" \
  "$ROOT_DIR"/Sources/*.swift

echo "[build] bundling .app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "[build] done: $APP_DIR"
