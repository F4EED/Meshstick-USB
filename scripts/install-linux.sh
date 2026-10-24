#!/bin/bash
# Installe meshtasticd pour un Meshstick USB (CH341 1a86:5512, SX1262).
# Ubuntu 22.04/24.04/25.10/26.04, Linux Mint 21/22 (et LMDE 6/7), Debian 12/13.
#   sudo bash scripts/install-linux.sh
set -euo pipefail

OWNER="${MESHSTICK_OWNER:-Meshstick}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
    echo "Lancez ce script avec sudo : sudo bash scripts/install-linux.sh" >&2
    exit 1
fi

if [ ! -r /etc/os-release ]; then
    echo "Distribution inconnue : /etc/os-release est absent." >&2
    exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release

export DEBIAN_FRONTEND=noninteractive

meshstick_network_ok() {
    local host
    for host in github.com ppa.launchpadcontent.net download.opensuse.org archive.ubuntu.com; do
        if command -v curl >/dev/null 2>&1; then
            curl -fsI --max-time 12 "https://$host/" >/dev/null 2>&1 && return 0
        elif command -v wget >/dev/null 2>&1; then
            wget -q --spider --timeout=12 "https://$host/" >/dev/null 2>&1 && return 0
        elif command -v timeout >/dev/null 2>&1; then
            timeout 8 bash -c "echo >/dev/tcp/$host/443" >/dev/null 2>&1 && return 0
        fi
    done
    return 1
}

check_install_prereqs() {
    local arch avail
    arch=$(uname -m)
    case "$arch" in
        x86_64|aarch64|arm64)
            echo "Prerequis OK : architecture $arch"
            ;;
        *)
            echo "Architecture $arch non prise en charge pour meshtasticd. Attendu : x86_64 ou aarch64." >&2
            exit 1
            ;;
    esac
    avail=$(df -Pk / | awk 'NR==2 {print $4}')
    if [ -z "${avail:-}" ] || [ "$avail" -lt 1048576 ]; then
        echo "Il faut au moins 1 Go libre sur / pour installer meshtasticd et le client meshtastic." >&2
        exit 1
    fi
    echo "Prerequis OK : $((avail / 1024)) Mo libres sur /"
    if [ -x /usr/bin/meshtasticd ]; then
        echo "Prerequis OK : meshtasticd deja installe"
        return 0
    fi
    if ! meshstick_network_ok; then
        echo "Acces reseau requis vers les depots Meshtastic (Launchpad, openSUSE ou archive.ubuntu.com)." >&2
        exit 1
    fi
    echo "Prerequis OK : reseau"
}

install_root=/Apps/Meshstick
repo_root=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
if [ "$repo_root" != "$install_root" ]; then
    echo "Copie des fichiers vers $install_root"
    mkdir -p "$install_root/scripts" "$install_root/images"
    cp -a "$SCRIPT_DIR/." "$install_root/scripts/"
    for name in README.md LICENSE .gitattributes; do
        if [ -f "$repo_root/$name" ]; then
            cp -a "$repo_root/$name" "$install_root/$name"
        fi
    done
    if [ -d "$repo_root/images" ]; then
        cp -a "$repo_root/images/." "$install_root/images/"
    fi
    SCRIPT_DIR=$install_root/scripts
fi

require_ubuntu_codename() {
    case "$1" in
        jammy|noble|questing|resolute) ;;
        *)
            echo "Le PPA Meshtastic ne publie pas pour le codename Ubuntu '$1'." >&2
            echo "Attendu : jammy (22.04), noble (24.04), questing (25.10), resolute (26.04)." >&2
            echo "Linux Mint 21 utilise jammy, Linux Mint 22 utilise noble." >&2
            exit 1
            ;;
    esac
}

install_ubuntu() {
    local codename="$1"
    require_ubuntu_codename "$codename"
    apt-get update
    apt-get install -y ca-certificates curl gnupg software-properties-common
    if [ "${ID:-}" = "ubuntu" ]; then
        add-apt-repository -y ppa:meshtastic/beta
    else
        # Linux Mint annonce son propre codename (wilma, xia). Le PPA n'a que ceux d'Ubuntu.
        install -d /etc/apt/keyrings
        rm -f /etc/apt/keyrings/meshtastic-beta.gpg
        curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x5E0A0F83F3DDE7AC55915B14F40C93FFA2CD17E3" \
            | gpg --dearmor -o /etc/apt/keyrings/meshtastic-beta.gpg
        chmod 644 /etc/apt/keyrings/meshtastic-beta.gpg
        cat > /etc/apt/sources.list.d/meshtastic-beta.sources <<EOF
Types: deb
URIs: https://ppa.launchpadcontent.net/meshtastic/beta/ubuntu/
Suites: ${codename}
Components: main
Signed-By: /etc/apt/keyrings/meshtastic-beta.gpg
EOF
    fi
    apt-get update
    apt-get install -y meshtasticd python3-pip python3-venv pipx usbutils
}

debian_suite_for() {
    case "$1" in
        bookworm|12) echo Debian_12 ;;
        trixie|13) echo Debian_13 ;;
        *)
            echo "Debian ou LMDE '$1' n'est pas pris en charge. Utilisez Debian 12 (bookworm) ou 13 (trixie), ou LMDE 6/7." >&2
            return 1
            ;;
    esac
}

install_debian() {
    local token="$1"
    local suite
    suite=$(debian_suite_for "$token")
    apt-get update
    apt-get install -y curl gnupg ca-certificates pipx usbutils
    echo "deb http://download.opensuse.org/repositories/network:/Meshtastic:/beta/${suite}/ /" \
        > /etc/apt/sources.list.d/network:Meshtastic:beta.list
    rm -f /etc/apt/trusted.gpg.d/network_Meshtastic_beta.gpg
    curl -fsSL "https://download.opensuse.org/repositories/network:Meshtastic:beta/${suite}/Release.key" \
        | gpg --dearmor -o /etc/apt/trusted.gpg.d/network_Meshtastic_beta.gpg
    apt-get update
    apt-get install -y meshtasticd
}

check_install_prereqs

case "${ID:-}" in
    ubuntu)
        install_ubuntu "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
        ;;
    linuxmint)
        if [ -n "${UBUNTU_CODENAME:-}" ]; then
            install_ubuntu "$UBUNTU_CODENAME"
        elif [ -n "${DEBIAN_CODENAME:-}" ]; then
            install_debian "$DEBIAN_CODENAME"
        else
            echo "Linux Mint : UBUNTU_CODENAME et DEBIAN_CODENAME sont absents de /etc/os-release." >&2
            exit 1
        fi
        ;;
    debian)
        if [ "${NAME:-}" = "Raspbian GNU/Linux" ] || echo "${NAME:-}" | grep -q '^Raspbian'; then
            echo "Raspberry Pi OS 32 bits : utilisez les depots Raspbian Meshtastic, pas ce script Debian." >&2
            exit 1
        fi
        install_debian "${VERSION_ID:-}"
        ;;
    raspbian)
        echo "Raspberry Pi OS 32 bits : utilisez les depots Raspbian decrits sur meshtastic.org." >&2
        exit 1
        ;;
    *)
        echo "Distribution ${ID:-inconnue} non gerée par ce script (Ubuntu, Linux Mint, Debian 12/13)." >&2
        exit 1
        ;;
esac

python3 - <<'PY'
import sys
version = "%d.%d.%d" % sys.version_info[:3]
if sys.version_info < (3, 8):
    raise SystemExit(
        "Python 3.8 ou plus recent est requis pour le client meshtastic. Version trouvee : %s" % version
    )
print("Prerequis OK : Python %s" % version)
PY

if [ ! -x /root/.local/bin/meshtastic ]; then
    pipx install meshtastic
fi
if [ -x /root/.local/bin/meshtastic ]; then
    ln -sfn /root/.local/bin/meshtastic /usr/local/bin/meshtastic
fi
if ! command -v meshtastic >/dev/null 2>&1; then
    echo "Le client meshtastic est introuvable apres pipx install." >&2
    exit 1
fi
echo "Prerequis OK : client meshtastic"
pipx ensurepath >/dev/null 2>&1 || true

install -d /etc/udev/rules.d /usr/local/sbin /etc/systemd/system/meshtasticd.service.d /etc/meshtasticd
printf '%s\n' "$OWNER" > /etc/meshtasticd/meshstick-owner
chmod 644 /etc/meshtasticd/meshstick-owner
sed 's/\r$//' "$SCRIPT_DIR/99-meshstick.rules" > /etc/udev/rules.d/99-meshstick.rules
sed 's/\r$//' "$SCRIPT_DIR/meshstick-usb-access.sh" > /usr/local/sbin/meshstick-usb-access
sed 's/\r$//' "$SCRIPT_DIR/meshstick-configure.sh" > /usr/local/sbin/meshstick-configure
chmod 755 /usr/local/sbin/meshstick-usb-access /usr/local/sbin/meshstick-configure
sed 's/\r$//' "$SCRIPT_DIR/meshstick-plug.service" > /etc/systemd/system/meshstick-plug.service
cat > /etc/systemd/system/meshtasticd.service.d/usb-access.conf <<'EOF'
[Service]
ExecStartPre=+/usr/local/sbin/meshstick-usb-access
Restart=always
RestartSec=5
StartLimitIntervalSec=0
EOF

python3 - <<'PY'
from pathlib import Path
p = Path("/etc/meshtasticd/config.yaml")
text = p.read_text() if p.exists() else ""
text = text.replace(
    "#  Port: 9443 # Port for Webserver & Webservices",
    "  Port: 9443 # Port for Webserver & Webservices",
)
text = text.replace(
    "#  RootPath: /usr/share/meshtasticd/web # Root Dir of WebServer",
    "  RootPath: /usr/share/meshtasticd/web # Root Dir of WebServer",
)
if "Webserver:" not in text:
    if text and not text.endswith("\n"):
        text += "\n"
    text += "Webserver:\n  Port: 9443\n  RootPath: /usr/share/meshtasticd/web\n"
p.write_text(text)
PY

if ! grep -qi microsoft /proc/version 2>/dev/null; then
    if ! command -v google-chrome >/dev/null 2>&1 \
        && ! command -v google-chrome-stable >/dev/null 2>&1 \
        && ! command -v chromium >/dev/null 2>&1 \
        && ! command -v chromium-browser >/dev/null 2>&1; then
        apt-get install -y chromium || apt-get install -y chromium-browser || echo "Chrome ou Chromium absent : ouvrez https://127.0.0.1:9443 a la main."
    fi
    cat > /usr/share/applications/meshstick-usb.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Meshstick USB
Comment=Prepare le noeud Meshtastic et ouvre Chrome
Exec=bash "$SCRIPT_DIR/launch-linux.sh"
Icon=network-wireless
Terminal=true
Categories=Network;
EOF
    chmod 644 /usr/share/applications/meshstick-usb.desktop
    if [ -n "${SUDO_USER:-}" ]; then
        user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        for desk in "$user_home/Desktop" "$user_home/Bureau"; do
            if [ -d "$desk" ]; then
                cp /usr/share/applications/meshstick-usb.desktop "$desk/meshstick-usb.desktop"
                chown "$SUDO_USER:" "$desk/meshstick-usb.desktop"
                chmod 755 "$desk/meshstick-usb.desktop"
            fi
        done
    fi
    apt-get install -y avahi-daemon
    cat > /etc/avahi/services/meshtastic.service <<'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name>Meshtastic</name>
  <service protocol="ipv4">
    <type>_meshtastic._tcp</type>
    <port>4403</port>
  </service>
</service-group>
EOF
    systemctl enable avahi-daemon || true
    systemctl restart avahi-daemon || true
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow 4403/tcp || true
        ufw allow 9443/tcp || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=4403/tcp || true
        firewall-cmd --permanent --add-port=9443/tcp || true
        firewall-cmd --reload || true
    fi
fi

bash "$SCRIPT_DIR/meshstick-web-default.sh"

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules || true
        udevadm trigger --action=add --subsystem-match=usb || true
    fi
    systemctl enable meshtasticd
    systemctl reset-failed meshtasticd || true
    systemctl restart meshtasticd || true
    if command -v lsusb >/dev/null 2>&1 && lsusb | grep -q '1a86:5512'; then
        MESHSTICK_OWNER="$OWNER" /usr/local/sbin/meshstick-configure
    else
        echo "Stick non visible pour l'instant. Il sera configure a la prochaine insertion."
    fi
else
    echo "systemd n'est pas actif. Demarrez le noeud avec : sudo meshtasticd"
fi

echo "INSTALL_LINUX_OK"
