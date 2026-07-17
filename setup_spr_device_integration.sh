#!/bin/bash
# Install the SPR Core changes needed for DHCP-backed virtual plugin devices.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERDIR="${1:-${SUPERDIR:-/home/spr/super}}"
FIREWALL_GO="$SUPERDIR/api/code/firewall.go"
PLUGINS_GO="$SUPERDIR/api/code/plugins.go"
DHCP_DOCKERFILE="$SUPERDIR/dhcp/Dockerfile"
API_CHANGED=false
DHCP_CHANGED=false

if [ ! -f "$FIREWALL_GO" ] || [ ! -f "$PLUGINS_GO" ] ||
   [ ! -f "$DHCP_DOCKERFILE" ]; then
    echo "SPR source tree not found at $SUPERDIR" >&2
    exit 1
fi

apply_patch_once() {
    local marker_file="$1"
    local marker="$2"
    local patch="$3"
    local changed_var="$4"

    if sudo grep -Fq "$marker" "$marker_file"; then
        return
    fi
    if ! sudo git -c "safe.directory=$SUPERDIR" -C "$SUPERDIR" \
        apply --check "$patch"; then
        echo "Cannot apply $(basename "$patch"); the SPR source has diverged." >&2
        exit 1
    fi
    sudo git -c "safe.directory=$SUPERDIR" -C "$SUPERDIR" apply "$patch"
    printf -v "$changed_var" '%s' true
}

apply_patch_once \
    "$FIREWALL_GO" \
    "recentDHCPIfaces := map[string]string{}" \
    "$SCRIPT_DIR/patches/0004-super-route-authorized-dhcp-interface.patch" \
    API_CHANGED
apply_patch_once \
    "$PLUGINS_GO" \
    "DeviceMAC string" \
    "$SCRIPT_DIR/patches/0005-super-plugin-device-network-capabilities.patch" \
    API_CHANGED
apply_patch_once \
    "$DHCP_DOCKERFILE" \
    "COREDHCP_COMMIT=7fc806d5cb53eb17df6cae022c3bde9fe8f5946e" \
    "$SCRIPT_DIR/patches/0006-super-coredhcp-honor-broadcast.patch" \
    DHCP_CHANGED

if [ "$API_CHANGED" = true ]; then
    (
        cd "$SUPERDIR"
        sudo docker compose build api
        sudo docker compose up -d --no-deps --force-recreate api
    )
    echo "Installed SPR virtual-device API integration and restarted superapi."
fi
if [ "$DHCP_CHANGED" = true ]; then
    (
        cd "$SUPERDIR"
        sudo docker compose build dhcp
        sudo docker compose up -d --no-deps --force-recreate dhcp
    )
    echo "Installed the CoreDHCP broadcast fix and restarted superdhcp."
fi
if [ "$API_CHANGED" = false ] && [ "$DHCP_CHANGED" = false ]; then
    echo "SPR virtual-device integration is already installed."
fi
