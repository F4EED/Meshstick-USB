#!/bin/bash
# L'interface livree avec meshtasticd propose meshtastic.local quand la page
# est ouverte sur localhost. Ce nom part sur le port 443. Le serveur web est
# sur le port 9443 : on laisse l'adresse de la page, port compris.
set -eu
dir=/usr/share/meshtasticd/web
[ -d "$dir" ] || exit 0
find "$dir" -type f -name '*.js' -print0 | while IFS= read -r -d '' file; do
    if grep -q 'client.meshtastic.org","localhost' "$file"; then
        sed -i 's/\["client\.meshtastic\.org","localhost"\]/["client.meshtastic.org"]/g' "$file"
        echo "Adresse par defaut corrigee : $file"
    fi
done
