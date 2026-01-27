#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_DIR="${HOME}/.hammerspoon"
DATA_DIR="${HS_DIR}/data"
WORDLIST_DIR="${DATA_DIR}/wordlists"

mkdir -p "${HS_DIR}" "${DATA_DIR}" "${WORDLIST_DIR}"

backup_file() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    local ts
    ts="$(date +%Y%m%d%H%M%S)"
    cp "${path}" "${path}.bak.${ts}"
  fi
}

backup_file "${HS_DIR}/vocab_overlay.lua"
cp "${ROOT_DIR}/hammerspoon/vocab_overlay.lua" "${HS_DIR}/vocab_overlay.lua"

# Copy sample data only if the user doesn't already have them.
for f in "${ROOT_DIR}/hammerspoon/data/items.json" "${ROOT_DIR}/hammerspoon/data/sentences.txt"; do
  dest="${DATA_DIR}/$(basename "${f}")"
  if [[ ! -f "${dest}" ]]; then
    cp "${f}" "${dest}"
  fi
done

for f in "${ROOT_DIR}"/hammerspoon/data/wordlists/*.txt; do
  dest="${WORDLIST_DIR}/$(basename "${f}")"
  if [[ ! -f "${dest}" ]]; then
    cp "${f}" "${dest}"
  fi
done

INIT_FILE="${HS_DIR}/init.lua"
BOOT_LINE='pcall(function() require("vocab_overlay").start() end)'

if [[ ! -f "${INIT_FILE}" ]]; then
  cat >"${INIT_FILE}" <<EOF
-- Minimal bootstrap (created by mac-vocab-overlay/install.sh)
${BOOT_LINE}
EOF
else
  if ! grep -q 'require("vocab_overlay")' "${INIT_FILE}"; then
    {
      echo ""
      echo "-- Added by mac-vocab-overlay/install.sh"
      echo "${BOOT_LINE}"
    } >>"${INIT_FILE}"
  fi
fi

cat <<EOF
Installed:
  - ${HS_DIR}/vocab_overlay.lua
  - ${DATA_DIR}/generated_store.json (auto created on first run)

Next:
  1) Open Hammerspoon, grant Accessibility permission if prompted.
  2) Click Hammerspoon -> Reload Config
  3) In menu bar "EN" -> Settings… to configure your LLM.
EOF

