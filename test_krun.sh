#!/bin/bash
# Verify an already-running spr-atlas krun deployment on the SPR host.
set -euo pipefail

CONTAINER="${ATLAS_CONTAINER:-spr-atlas}"
EXPECTED_RUNTIME="${ATLAS_RUNTIME:-spr-krun}"
ATLAS_MAC="${ATLAS_MAC:-02:53:50:52:40:40}"
SUPERDIR="${1:-${SUPERDIR:-/home/spr/super/}}"
STATE_DIR="${SUPERDIR%/}/state/plugins/spr-atlas"
SOCKET="${STATE_DIR}/api/socket"
PUBLIC_DEVICES="${SUPERDIR%/}/state/public/devices-public.json"

if [ ! -c /dev/kvm ]; then
    echo "/dev/kvm is not available" >&2
    exit 1
fi
if [ ! -c /dev/net/tun ]; then
    echo "/dev/net/tun is not available" >&2
    exit 1
fi

RUNNING="$(docker inspect --format '{{.State.Running}}' "$CONTAINER")"
RUNTIME="$(docker inspect --format '{{.HostConfig.Runtime}}' "$CONTAINER")"
PID="$(docker inspect --format '{{.State.Pid}}' "$CONTAINER")"
CAPS="$(docker inspect --format '{{json .HostConfig.CapAdd}}' "$CONTAINER")"
NETWORK_MODE="$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$CONTAINER")"

if [ "$RUNNING" != "true" ]; then
    echo "$CONTAINER is not running" >&2
    exit 1
fi
if [ "$RUNTIME" != "$EXPECTED_RUNTIME" ]; then
    echo "$CONTAINER uses runtime '$RUNTIME', expected '$EXPECTED_RUNTIME'" >&2
    exit 1
fi
if [ "$NETWORK_MODE" != "spr-atlas" ]; then
    echo "$CONTAINER uses network '$NETWORK_MODE', expected private network 'spr-atlas'" >&2
    exit 1
fi
if ! jq -e 'sort == ["CAP_NET_RAW"]' <<<"$CAPS" >/dev/null; then
    echo "$CONTAINER capabilities are not limited to CAP_NET_RAW: $CAPS" >&2
    exit 1
fi
if docker inspect --format '{{.State.Running}}' spr-atlas-socket-proxy \
    2>/dev/null | grep -qx true; then
    echo "obsolete TCP socket proxy is still running" >&2
    exit 1
fi
if [ ! -S "$SOCKET" ]; then
    echo "host-visible plugin socket is missing: $SOCKET" >&2
    exit 1
fi
if ss -H -ltnp | grep -F "pid=$PID," >/dev/null; then
    echo "Atlas API unexpectedly has an IP listener" >&2
    ss -ltnp | grep -F "pid=$PID," >&2
    exit 1
fi

if [ "$(readlink /proc/1/ns/net)" = "$(readlink "/proc/${PID}/ns/net")" ]; then
    echo "Atlas VMM unexpectedly shares the host network namespace" >&2
    exit 1
fi
if ip link show dev kruntap0 >/dev/null 2>&1; then
    echo "Atlas TAP unexpectedly exists in the host network namespace" >&2
    exit 1
fi
for iface in eth0 kruntap0 krunbr0; do
    if ! nsenter -t "$PID" -n ip link show dev "$iface" >/dev/null 2>&1; then
        echo "missing Atlas private network interface: $iface" >&2
        exit 1
    fi
done
if nsenter -t "$PID" -n ip -4 addr show dev eth0 | grep -q 'inet '; then
    echo "Docker IP unexpectedly remains assigned to the VMM uplink" >&2
    exit 1
fi
if pgrep -x passt >/dev/null 2>&1; then
    CONTAINER_CGROUP="$(cat "/proc/${PID}/cgroup")"
    while read -r passt_pid; do
        if [ -r "/proc/${passt_pid}/cgroup" ] &&
            [ "$(cat "/proc/${passt_pid}/cgroup")" = "$CONTAINER_CGROUP" ]; then
            echo "passt is unexpectedly running in the Atlas container cgroup" >&2
            exit 1
        fi
    done < <(pgrep -x passt)
fi

if [ ! -r "$PUBLIC_DEVICES" ]; then
    echo "SPR public device state is missing: $PUBLIC_DEVICES" >&2
    exit 1
fi
DEVICE="$(jq -c --arg mac "$ATLAS_MAC" '.[$mac] // empty' "$PUBLIC_DEVICES")"
ATLAS_IP="$(jq -r '.RecentIP // empty' <<<"$DEVICE")"
ATLAS_IFACE="$(jq -r '.DHCPLastInterface // empty' <<<"$DEVICE")"
if [ -z "$ATLAS_IP" ] || [ "$ATLAS_IFACE" != "spr-atlas" ]; then
    echo "Atlas device $ATLAS_MAC has no SPR DHCP lease on spr-atlas" >&2
    printf 'device state: %s\n' "$DEVICE" >&2
    exit 1
fi
if ! jq -e '.Policies | index("wan") and index("dns")' <<<"$DEVICE" >/dev/null; then
    echo "Atlas device does not have wan+dns policy" >&2
    printf 'device state: %s\n' "$DEVICE" >&2
    exit 1
fi

STATUS=
for _ in $(seq 1 30); do
    if STATUS="$(
        curl --fail --silent --show-error \
            --unix-socket "$SOCKET" \
            http://localhost/status 2>/dev/null
    )"; then
        break
    fi
    sleep 1
done
if [ -z "$STATUS" ]; then
    echo "plugin API did not become ready: $SOCKET" >&2
    exit 1
fi
printf 'Atlas runtime: %s\n' "$RUNTIME"
printf 'Atlas device: %s (%s via SPR DHCP on %s)\n' "$ATLAS_MAC" "$ATLAS_IP" "$ATLAS_IFACE"
printf 'network: virtio-net -> private TAP/bridge -> spr-atlas (no passt)\n'
printf 'plugin IPC: host UDS -> virtio-vsock -> guest UDS (no IP listener)\n'
printf 'plugin API: %s\n' "$STATUS"

# krun intentionally does not implement OCI exec. Atlas performs an IPv4
# evping before registration, using the same unprivileged user, ambient
# CAP_NET_RAW handoff, SPR DHCP/DNS and virtio-net/TAP path as scheduled
# measurements. Check the in-memory logs from this boot rather than launching
# a second microVM with the same stable device identity.
for _ in $(seq 1 15); do
    LOGS="$(
        curl --fail --silent --show-error \
            --unix-socket "$SOCKET" \
            "http://localhost/logs?lines=1000"
    )"
    if grep -q 'Ping works' <<<"$LOGS"; then
        echo "Atlas DNS + raw-ICMP registration check: passed"
        echo "spr-atlas krun checks passed"
        exit 0
    fi
    sleep 2
done

echo "Atlas did not report a successful DNS + raw-ICMP registration check" >&2
printf 'recent Atlas logs: %s\n' "$LOGS" >&2
exit 1
