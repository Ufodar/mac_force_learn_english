#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacForceLearnEnglish"

bash "$ROOT_DIR/scripts/build.sh"
bash "$ROOT_DIR/scripts/make_dmg.sh"

if [[ "${NOTARIZE:-}" == "1" ]]; then
  bash "$ROOT_DIR/scripts/notarize.sh" "$ROOT_DIR/dist/$APP_NAME.dmg"
fi

# Default: clean build artifacts to avoid duplicate app copies / permission mismatch.
# Set KEEP_BUILD_APP=1 if you want to keep build/ MacForceLearnEnglish.app for local runs.
if [[ "${KEEP_BUILD_APP:-}" != "1" && "${CLEAN_BUILD_APP:-}" != "0" ]]; then
  rm -rf "$ROOT_DIR/build/$APP_NAME.app" "$ROOT_DIR/build/$APP_NAME"
fi

echo "[dist] outputs:"
echo "  $ROOT_DIR/dist/MacForceLearnEnglish.dmg"
