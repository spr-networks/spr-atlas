#!/bin/bash
# Command line install alternative to the UI
set -euo pipefail

ATLAS_RUNTIME="${ATLAS_RUNTIME:-spr-krun}"
ATLAS_MAC="${ATLAS_MAC:-02:53:50:52:40:40}"
ATLAS_INTERFACE="spr-atlas"
export ATLAS_RUNTIME
export ATLAS_MAC

if [ ! -c /dev/kvm ]; then
  echo "spr-atlas requires KVM, but /dev/kvm is not available." >&2
  exit 1
fi

if ! docker info --format '{{json .Runtimes}}' | grep -Fq "\"${ATLAS_RUNTIME}\""; then
  echo "Docker runtime '${ATLAS_RUNTIME}' is not installed." >&2
  echo "Install the SPR crun/libkrun host package, which registers 'spr-krun'." >&2
  exit 1
fi

if [ ! -c /dev/net/tun ]; then
  echo "spr-atlas requires the host TAP device /dev/net/tun." >&2
  exit 1
fi

echo "Please enter your SPR path (/home/spr/super/)"
read -r SUPERDIR

if [ -z "$SUPERDIR" ]; then
    SUPERDIR="/home/spr/super/"
fi

export SUPERDIR

if ! grep -Fq 'recentDHCPIfaces := map[string]string{}' \
  "$SUPERDIR/api/code/firewall.go" 2>/dev/null; then
  echo "SPR virtual-device routing support is not installed." >&2
  echo "Upgrade SPR to a release that includes krun plugin-device networking." >&2
  exit 1
fi

echo "Please enter your SPR API token:"
read -r SPR_API_TOKEN

if [ -z "$SPR_API_TOKEN" ]; then
  echo "need api token, generate one on the auth keys page"
  exit 1
fi

mkdir -p "$SUPERDIR/configs/plugins/spr-atlas"
mkdir -p "$SUPERDIR/state/plugins/spr-atlas"
mkdir -p "$SUPERDIR/state/plugins/spr-atlas/api"

# InstallTokenPath equivalent (the backend does not call the SPR API today,
# but the file matches plugin.json for UI-installed parity).
printf '%s' "$SPR_API_TOKEN" > "$SUPERDIR/configs/plugins/spr-atlas/api-token"
chmod 600 "$SUPERDIR/configs/plugins/spr-atlas/api-token"

# The VM is a first-class SPR device. Seed its stable MAC before it asks for a
# lease so the first DHCP transaction receives the intended wan+dns policy.
API=127.0.0.1
curl --fail-with-body --silent --show-error \
  "http://${API}/device?identity=${ATLAS_MAC}" \
  -H "Authorization: Bearer ${SPR_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -X 'PUT' \
  --data-raw "{\"MAC\":\"${ATLAS_MAC}\",\"Name\":\"spr-atlas\",\"Policies\":[\"wan\",\"dns\"],\"Groups\":[]}" \
  >/dev/null

# The UI plugin path installs this exact authorization from plugin.json.
# Mirror it for the command-line compose path.
if ! sudo nft get element inet filter dhcp_access \
  "{ \"${ATLAS_INTERFACE}\" . ${ATLAS_MAC} }" >/dev/null 2>&1; then
  sudo nft add element inet filter dhcp_access \
    "{ \"${ATLAS_INTERFACE}\" . ${ATLAS_MAC} : accept }"
fi

# During local development, build the sibling template and use Docker's
# default builder so the Atlas FROM can resolve that daemon-local image.
KRUN_PLUGIN_DIR="${SPR_KRUN_PLUGIN_DIR:-../spr-krun-plugin}"
if [ -f "$KRUN_PLUGIN_DIR/Dockerfile" ]; then
  docker build \
    -t ghcr.io/spr-networks/spr-krun-plugin:latest \
    "$KRUN_PLUGIN_DIR"
  export SPR_ATLAS_BUILDER="${SPR_ATLAS_BUILDER:-default}"
fi

./build_docker_compose.sh --load
docker compose -f docker-compose-kvm.yml up -d --remove-orphans

ATLAS_IP=
for _ in $(seq 1 30); do
  DEVICE="$(
    curl --fail-with-body --silent --show-error \
      "http://${API}/device?identity=${ATLAS_MAC}" \
      -H "Authorization: Bearer ${SPR_API_TOKEN}"
  )"
  ATLAS_IP="$(jq -r '.RecentIP // empty' <<<"$DEVICE")"
  LEASE_IFACE="$(jq -r '.DHCPLastInterface // empty' <<<"$DEVICE")"
  if [ -n "$ATLAS_IP" ] && [ "$LEASE_IFACE" = "$ATLAS_INTERFACE" ]; then
    break
  fi
  sleep 1
done
if [ -z "$ATLAS_IP" ] || [ "${LEASE_IFACE:-}" != "$ATLAS_INTERFACE" ]; then
  echo "spr-atlas did not obtain an SPR DHCP lease on interface $ATLAS_INTERFACE" >&2
  exit 1
fi

echo ""
echo "SPR assigned ${ATLAS_IP} to Atlas device ${ATLAS_MAC}."
echo "Done. The probe public key:"
KEY_PATH="$SUPERDIR/state/plugins/spr-atlas/etc/probe_key.pub"
for _ in $(seq 1 30); do
  if [ -s "$KEY_PATH" ]; then
    break
  fi
  sleep 1
done
if [ ! -s "$KEY_PATH" ]; then
  echo "spr-atlas did not generate its public key within 30 seconds" >&2
  exit 1
fi
cat "$KEY_PATH"
echo ""
echo "Register it at https://atlas.ripe.net/apply/swprobe/"
