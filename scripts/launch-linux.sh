#!/bin/bash
# Installe meshtasticd si besoin, regle la radio, demarre le noeud, ouvre Chrome.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bash "$script_dir/meshstick-ensure.sh"

url="https://127.0.0.1:9443"
echo "Interface : $url"
if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    exit 0
fi

browser=()
if command -v google-chrome >/dev/null 2>&1; then
    browser=(google-chrome --new-window)
elif command -v google-chrome-stable >/dev/null 2>&1; then
    browser=(google-chrome-stable --new-window)
elif command -v chromium >/dev/null 2>&1; then
    browser=(chromium --new-window)
elif command -v chromium-browser >/dev/null 2>&1; then
    browser=(chromium-browser --new-window)
elif command -v xdg-open >/dev/null 2>&1; then
    browser=(xdg-open)
fi

if [ "${#browser[@]}" -eq 0 ]; then
    exit 0
fi

if [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" "${browser[@]}" "$url" >/dev/null 2>&1 || true
else
    "${browser[@]}" "$url" >/dev/null 2>&1 || true
fi
