#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

bash "$ROOT_DIR/scripts/build.sh"
bash "$ROOT_DIR/scripts/make_dmg.sh"

echo "[dist] outputs:"
echo "  $ROOT_DIR/dist/MacForceLearnEnglish.dmg"
