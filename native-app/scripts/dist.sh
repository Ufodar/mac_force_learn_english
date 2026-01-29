#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacForceLearnEnglish"

bash "$ROOT_DIR/scripts/build.sh"
bash "$ROOT_DIR/scripts/make_dmg.sh"

if [[ "${NOTARIZE:-}" == "1" ]]; then
  bash "$ROOT_DIR/scripts/notarize.sh" "$ROOT_DIR/dist/$APP_NAME.dmg"
fi

if [[ "${CLEAN_BUILD_APP:-}" == "1" ]]; then
  rm -rf "$ROOT_DIR/build/$APP_NAME.app" "$ROOT_DIR/build/$APP_NAME"
fi

echo "[dist] outputs:"
echo "  $ROOT_DIR/dist/MacForceLearnEnglish.dmg"
