#!/bin/bash
# A chaque installation et a chaque lancement :
#   3. meshtasticd est installe s'il manque
#   4. la radio Gaulix 868 et le canal alerte sont poses
#   5. le service est demarre s'il est arrete
set -eu

OWNER="${MESHSTICK_OWNER:-Meshstick}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
    echo "Lancez ce script en root." >&2
    exit 1
fi

if [ ! -x /usr/bin/meshtasticd ]; then
    exec env MESHSTICK_OWNER="$OWNER" bash "$SCRIPT_DIR/install-linux.sh"
fi

sed 's/\r$//' "$SCRIPT_DIR/meshstick-configure.sh" > /usr/local/sbin/meshstick-configure
chmod 755 /usr/local/sbin/meshstick-configure
bash "$SCRIPT_DIR/meshstick-web-default.sh"

if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    echo "systemd est inactif. Demarrez le noeud avec : sudo meshtasticd" >&2
    exit 1
fi

systemctl enable meshtasticd >/dev/null 2>&1 || true
if ! systemctl is-active --quiet meshtasticd; then
    systemctl reset-failed meshtasticd || true
    systemctl restart meshtasticd
fi

if command -v lsusb >/dev/null 2>&1 && lsusb | grep -q '1a86:5512'; then
    MESHSTICK_OWNER="$OWNER" /usr/local/sbin/meshstick-configure
else
    echo "Stick non visible. La radio sera reglee au prochain branchement."
fi

echo "MESHSTICK_ENSURE_OK"
