#!/bin/bash
# Profil Gaulix 868 plus le canal local alerte (PSK AQ==, soit "default").
# N'utilise pas --seturl : ce remplacement efface les canaux ajoutes et
# redemarre le noeud au milieu de l'ecriture.
set -eu
OWNER="${MESHSTICK_OWNER:-}"
if [ -z "$OWNER" ] && [ -r /etc/meshtasticd/meshstick-owner ]; then
    OWNER=$(head -n 1 /etc/meshtasticd/meshstick-owner)
fi
if [ -z "$OWNER" ]; then
    OWNER=Meshstick
fi
CLI=$(command -v meshtastic || true)
if [ -z "$CLI" ] && [ -x /usr/local/bin/meshtastic ]; then
    CLI=/usr/local/bin/meshtastic
fi
if [ -z "$CLI" ] && [ -x /root/.local/bin/meshtastic ]; then
    CLI=/root/.local/bin/meshtastic
fi
if [ -z "$CLI" ]; then
    exit 0
fi

info=""
wait_info() {
    local n=0
    info=""
    while [ "$n" -lt 20 ]; do
        info=$("$CLI" --host localhost --info 2>/dev/null || true)
        if printf '%s' "$info" | grep -q 'Owner:'; then
            return 0
        fi
        n=$((n + 1))
        sleep 2
    done
    return 1
}

has_name() {
    printf '%s' "$info" | grep -q "\"name\": \"$1\""
}

wait_info || exit 0

if ! printf '%s' "$info" | grep -q 'LONG_MODERATE'; then
    "$CLI" --host localhost --set lora.region EU_868 --set lora.modem_preset LONG_MODERATE --set lora.override_frequency 869.4625 --set lora.hop_limit 3 --set-owner "$OWNER" || true
    sleep 8
    wait_info || exit 0
fi

if ! has_name Fr_Balise; then
    "$CLI" --host localhost --ch-index 0 --ch-set name Fr_Balise --ch-set psk default --ch-set uplink_enabled true --ch-set downlink_enabled true || true
    sleep 8
    wait_info || exit 0
fi

for channel in Fr_EMCOM Fr_BlaBla alerte; do
    if has_name "$channel"; then
        continue
    fi
    "$CLI" --host localhost --ch-add "$channel" --ch-set psk default --ch-set uplink_enabled true --ch-set downlink_enabled true || true
    sleep 8
    wait_info || exit 0
done
