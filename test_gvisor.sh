#!/bin/bash
# Verify an already-running spr-atlas deployment on the SPR host.
set -euo pipefail

CONTAINER="${ATLAS_CONTAINER:-spr-atlas}"
EXPECTED_RUNTIME="${ATLAS_RUNTIME:-runsc-net-raw}"
SUPERDIR="${1:-${SUPERDIR:-/home/spr/super/}}"
STATE_DIR="${SUPERDIR%/}/state/plugins/spr-atlas"
SOCKET="${STATE_DIR}/api/socket"

if [ "$(uname -m)" = "aarch64" ] &&
   [ "$(getconf PAGESIZE)" -eq 16384 ]; then
    echo "This ARM64 host uses unsupported 16 KiB pages; runsc cannot start." >&2
    exit 1
fi

if [ -r /sys/fs/cgroup/cgroup.controllers ] &&
   ! grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
    echo "Host cgroup v2 is missing its mandatory memory controller." >&2
    echo "Enable cgroup_enable=memory cgroup_memory=1 at boot, then reboot." >&2
    exit 1
fi

RUNNING="$(docker inspect --format '{{.State.Running}}' "$CONTAINER")"
RUNTIME="$(docker inspect --format '{{.HostConfig.Runtime}}' "$CONTAINER")"

if [ "$RUNNING" != "true" ]; then
    echo "$CONTAINER is not running" >&2
    exit 1
fi
if [ "$RUNTIME" != "$EXPECTED_RUNTIME" ]; then
    echo "$CONTAINER uses runtime '$RUNTIME', expected '$EXPECTED_RUNTIME'" >&2
    exit 1
fi
if [ ! -S "$SOCKET" ]; then
    echo "host-visible plugin socket is missing: $SOCKET" >&2
    exit 1
fi

STATUS="$(
    curl --fail --silent --show-error \
        --unix-socket "$SOCKET" \
        http://localhost/status
)"
printf 'runtime: %s\n' "$RUNTIME"
printf 'plugin API: %s\n' "$STATUS"

# This is the same raw-ICMP measurement applet and capability handoff used by
# the probe. A successful RTT proves that runsc retained NET_RAW and that the
# sandbox has working DNS plus outbound ICMP.
PING_RESULT="$(
    docker exec "$CONTAINER" sh -lc '
        out=/var/spool/ripe-atlas/data/new/gvisor-smoke-ping
        rm -f "$out"
        trap "rm -f \"$out\"" EXIT
        setpriv \
            --reuid ripe-atlas \
            --regid ripe-atlas \
            --init-groups \
            --inh-caps +net_raw \
            --ambient-caps +net_raw \
            /usr/libexec/ripe-atlas/measurement/evping \
            -4 -A 9017 -e -O "$out" U1.1.sos.atlas.ripe.net
        cat "$out"
    '
)"
printf 'Atlas ICMP: %s\n' "$PING_RESULT"

if ! grep -q '"proto":"ICMP"' <<<"$PING_RESULT" ||
   ! grep -q '"rtt"' <<<"$PING_RESULT"; then
    echo "Atlas raw-ICMP smoke test did not return an RTT" >&2
    exit 1
fi

echo "spr-atlas gVisor checks passed"
