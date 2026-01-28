#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

bash "$ROOT_DIR/scripts/build.sh"
bash "$ROOT_DIR/scripts/make_dmg.sh"

mkdir -p "$ROOT_DIR/dist"
cp -R "$ROOT_DIR/build/MacForceLearnEnglish.app" "$ROOT_DIR/dist/MacForceLearnEnglish.app"

echo "[dist] outputs:"
echo "  $ROOT_DIR/dist/MacForceLearnEnglish.app"
echo "  $ROOT_DIR/dist/MacForceLearnEnglish.dmg"

