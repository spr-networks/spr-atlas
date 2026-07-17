#!/bin/bash
# spr-atlas container entrypoint: prepare the RIPE Atlas probe runtime layout,
# generate the probe ssh keypair on first start, then hand over to the plugin
# binary which supervises the probe main loop and serves the API/UI socket.
set -e

# runsc strips CAP_NET_RAW unless its runtime is configured with
# --net-raw=true. Fail before creating probe state rather than starting a
# probe that can register but cannot perform ICMP measurements.
if ! setpriv --dump | grep -q '^Capability bounding set:.*net_raw'; then
    echo "spr-atlas requires CAP_NET_RAW; configure runsc with --net-raw=true" >&2
    exit 1
fi

ATLAS_USER=ripe-atlas
ATLAS_ETC=/etc/ripe-atlas
ATLAS_CONFIG="$ATLAS_ETC/config.txt"
ATLAS_SPOOL=/var/spool/ripe-atlas
ATLAS_RUN=/run/ripe-atlas
STATE_DIR=/state/plugins/spr-atlas

mkdir -p "$STATE_DIR/log"

# /etc/ripe-atlas is a bind mount from $STATE_DIR/etc (persistent). Seed it
# from the image defaults on first start (mode file, install defaults).
if [ ! -f "$ATLAS_ETC/mode" ]; then
    cp -a /usr/share/ripe-atlas-defaults/. "$ATLAS_ETC/"
fi

# Installing this dedicated plugin is an explicit opt-in to hosting an Atlas
# probe, including RIPE's optional interface traffic-statistics reporting.
# Enforce the setting on every start so existing installations also receive it,
# while preserving any other supported runtime options in config.txt.
if grep -q '^[[:space:]]*RXTXRPT=' "$ATLAS_CONFIG" 2>/dev/null; then
    sed -i 's/^[[:space:]]*RXTXRPT=.*/RXTXRPT=yes/' "$ATLAS_CONFIG"
else
    printf 'RXTXRPT=yes\n' >> "$ATLAS_CONFIG"
fi

# Probe identity: an ssh keypair generated locally on first start. The ADMIN
# registers the PUBLIC key at https://atlas.ripe.net/apply/swprobe/ (shown in
# the plugin UI). The private key never leaves $STATE_DIR/etc.
if [ ! -f "$ATLAS_ETC/probe_key" ]; then
    ssh-keygen -t rsa -b 3072 -P '' -C "spr-atlas-$(hostname)" -f "$ATLAS_ETC/probe_key"
fi
chmod 600 "$ATLAS_ETC/probe_key"
chmod 644 "$ATLAS_ETC/probe_key.pub"
chmod 644 "$ATLAS_CONFIG"

# Runtime dirs (equivalent of upstream's tmpfiles.d/ripe-atlas.conf).
mkdir -p "$ATLAS_RUN/pids" "$ATLAS_RUN/status"
mkdir -p "$ATLAS_SPOOL/data/new" "$ATLAS_SPOOL/data/out/ooq" "$ATLAS_SPOOL/data/out/ooq10" "$ATLAS_SPOOL/data/oneoff"
mkdir -p "$ATLAS_SPOOL/crons/main"
for i in $(seq 2 20); do mkdir -p "$ATLAS_SPOOL/crons/$i"; done

# eooqd consumes crons/oneoff as a queue file and temporarily renames it to
# oneoff.curr. Older plugin images incorrectly created both paths as directories
# in the persistent spool, causing an endless "unlink failed: Is a directory"
# loop. Remove only those legacy directories when empty; never delete queue data.
for queue_path in "$ATLAS_SPOOL/crons/oneoff" "$ATLAS_SPOOL/crons/oneoff.curr"; do
    if [ -d "$queue_path" ] && ! rmdir "$queue_path"; then
        echo "Refusing to remove non-empty Atlas queue directory: $queue_path" >&2
        exit 1
    fi
done

# The probe runs unprivileged; the bind-mounted dirs are created root-owned
# by docker, so fix ownership every start.
chown -R "$ATLAS_USER:$ATLAS_USER" "$ATLAS_ETC" "$ATLAS_SPOOL" "$ATLAS_RUN"
chmod 770 "$ATLAS_ETC"

# The plugin binary supervises the probe (see code/probe.go): it launches
# /scripts/run-probe.sh, captures its output, and exposes status/restart.
exec /spr_atlas_plugin
