#!/bin/sh
# Donne au compte meshtasticd l'acces en ecriture au CH341 (1a86:5512).
# usbipd sous WSL cree souvent le noeud en root:root 0664, et udev ne le
# reprend pas toujours. Ce script est appele avant le demarrage du service.
set -eu
for dev in /sys/bus/usb/devices/*; do
    [ -f "$dev/idVendor" ] || continue
    vendor=$(cat "$dev/idVendor")
    product=$(cat "$dev/idProduct")
    if [ "$vendor" = "1a86" ] && [ "$product" = "5512" ]; then
        bus=$(cat "$dev/busnum")
        addr=$(cat "$dev/devnum")
        node=$(printf "/dev/bus/usb/%03d/%03d" "$bus" "$addr")
        if [ -e "$node" ]; then
            chgrp meshtasticd "$node"
            chmod 0660 "$node"
        fi
    fi
done
exit 0
