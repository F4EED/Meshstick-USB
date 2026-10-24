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

if ! id meshtasticd >/dev/null 2>&1; then
    echo "Prerequis d'utilisation manquant : le compte meshtasticd est absent. Relancez l'installation." >&2
    exit 1
fi
echo "Prerequis OK : compte meshtasticd"

if ! command -v meshtastic >/dev/null 2>&1; then
    echo "Client meshtastic absent. Installation avec pipx."
    if ! command -v pipx >/dev/null 2>&1; then
        echo "Prerequis d'utilisation manquant : pipx est absent. Relancez scripts/install-linux.sh." >&2
        exit 1
    fi
    pipx install meshtastic
    if [ -x /root/.local/bin/meshtastic ]; then
        ln -sfn /root/.local/bin/meshtastic /usr/local/bin/meshtastic
    fi
fi
if ! command -v meshtastic >/dev/null 2>&1; then
    echo "Prerequis d'utilisation manquant : le client meshtastic est introuvable." >&2
    exit 1
fi
if ! meshtastic --help >/dev/null 2>&1; then
    echo "Prerequis d'utilisation manquant : le client meshtastic ne demarre pas (Python 3.8 ou plus recent)." >&2
    exit 1
fi
echo "Prerequis OK : client meshtastic"

if ! grep -Eq '^[[:space:]]*Port:[[:space:]]*9443([[:space:]]|$)' /etc/meshtasticd/config.yaml 2>/dev/null; then
    echo "Prerequis d'utilisation manquant : Port 9443 absent de /etc/meshtasticd/config.yaml. Relancez l'installation." >&2
    exit 1
fi
echo "Prerequis OK : interface web port 9443"

sed 's/\r$//' "$SCRIPT_DIR/meshstick-configure.sh" > /usr/local/sbin/meshstick-configure
chmod 755 /usr/local/sbin/meshstick-configure
bash "$SCRIPT_DIR/meshstick-web-default.sh"

if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    echo "Prerequis d'utilisation manquant : systemd est inactif. Sous WSL, /etc/wsl.conf doit contenir systemd=true, puis wsl --shutdown." >&2
    exit 1
fi
echo "Prerequis OK : systemd"

systemctl enable meshtasticd >/dev/null 2>&1 || true
if ! systemctl is-active --quiet meshtasticd; then
    systemctl reset-failed meshtasticd || true
    systemctl restart meshtasticd
fi

if ! command -v lsusb >/dev/null 2>&1; then
    echo "Prerequis d'utilisation manquant : lsusb est absent (paquet usbutils)." >&2
    exit 1
fi
if lsusb | grep -q '1a86:5512'; then
    echo "Prerequis OK : cle 1a86:5512"
    MESHSTICK_OWNER="$OWNER" /usr/local/sbin/meshstick-configure
    i=0
    while [ "$i" -lt 40 ]; do
        if bash -c 'echo >/dev/tcp/127.0.0.1/9443' >/dev/null 2>&1; then
            echo "Prerequis OK : meshtasticd ecoute sur 9443"
            echo "MESHSTICK_ENSURE_OK"
            exit 0
        fi
        i=$((i + 1))
        sleep 1
    done
    echo "Prerequis d'utilisation manquant : meshtasticd n'ecoute pas sur le port 9443. journalctl -u meshtasticd -n 40 --no-pager" >&2
    exit 1
fi
echo "Stick non visible. Vissez l'antenne, branchez la cle 1a86:5512 : la radio sera reglee au branchement."

echo "MESHSTICK_ENSURE_OK"
