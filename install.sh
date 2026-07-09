#!/bin/bash
# Command line install alternative to the UI
echo "Please enter your SPR path (/home/spr/super/)"
read -r SUPERDIR

if [ -z "$SUPERDIR" ]; then
    SUPERDIR="/home/spr/super/"
fi

export SUPERDIR

echo "Please enter your SPR API token:"
read -r SPR_API_TOKEN

if [ -z "$SPR_API_TOKEN" ]; then
  echo "need api token, generate one on the auth keys page"
  exit 1
fi

mkdir -p "$SUPERDIR/configs/plugins/spr-atlas"
mkdir -p "$SUPERDIR/state/plugins/spr-atlas"

# InstallTokenPath equivalent (the backend does not call the SPR API today,
# but the file matches plugin.json for UI-installed parity).
printf '%s' "$SPR_API_TOKEN" > "$SUPERDIR/configs/plugins/spr-atlas/api-token"
chmod 600 "$SUPERDIR/configs/plugins/spr-atlas/api-token"

./build_docker_compose.sh --load
docker compose up -d

API=127.0.0.1
CONTAINER_IP=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "spr-atlas")

# Grant the plugin bridge outbound internet + DNS (no lan, no api).
curl "http://${API}/firewall/custom_interface" \
  -H "Authorization: Bearer ${SPR_API_TOKEN}" \
  -X 'PUT' \
  --data-raw "{\"SrcIP\":\"${CONTAINER_IP}\",\"Interface\":\"spr-atlas\",\"Policies\":[\"wan\",\"dns\"]}"

echo ""
echo "Done. The probe public key:"
docker exec spr-atlas cat /etc/ripe-atlas/probe_key.pub 2>/dev/null || \
  cat "$SUPERDIR/state/plugins/spr-atlas/etc/probe_key.pub" 2>/dev/null
echo ""
echo "Register it at https://atlas.ripe.net/apply/swprobe/"
