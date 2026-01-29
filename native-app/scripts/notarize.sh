#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacForceLearnEnglish"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="${1:-$DIST_DIR/$APP_NAME.dmg}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "[notary] missing dmg: $DMG_PATH" >&2
  exit 1
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [[ -z "$NOTARY_PROFILE" ]]; then
  cat >&2 <<EOF
[notary] NOTARY_PROFILE is required.

One-time setup example:
  xcrun notarytool store-credentials "MacForceLearnEnglish-notary" \\
    --apple-id "you@example.com" --team-id "YOURTEAMID" --password "xxxx-xxxx-xxxx-xxxx"

Then run:
  NOTARY_PROFILE="MacForceLearnEnglish-notary" bash native-app/scripts/notarize.sh
EOF
  exit 2
fi

echo "[notary] submit: $DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "[notary] staple: $DMG_PATH"
xcrun stapler staple "$DMG_PATH"

echo "[notary] verify: $DMG_PATH"
spctl -a -vv --type open "$DMG_PATH" || true
