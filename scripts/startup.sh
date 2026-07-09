#!/bin/bash
# spr-atlas container entrypoint: prepare the RIPE Atlas probe runtime layout,
# generate the probe ssh keypair on first start, then hand over to the plugin
# binary which supervises the probe main loop and serves the API/UI socket.
set -a
. /configs/base/config.sh
if [ -f /configs/spr-atlas/config.sh ]; then
    . /configs/spr-atlas/config.sh
fi
set +a

ATLAS_USER=ripe-atlas
ATLAS_ETC=/etc/ripe-atlas
ATLAS_SPOOL=/var/spool/ripe-atlas
ATLAS_RUN=/run/ripe-atlas
STATE_DIR=/state/plugins/spr-atlas

mkdir -p "$STATE_DIR/log"

# /etc/ripe-atlas is a bind mount from $STATE_DIR/etc (persistent). Seed it
# from the image defaults on first start (mode file, install defaults).
if [ ! -f "$ATLAS_ETC/mode" ]; then
    cp -a /usr/share/ripe-atlas-defaults/. "$ATLAS_ETC/"
fi

# Probe identity: an ssh keypair generated locally on first start. The ADMIN
# registers the PUBLIC key at https://atlas.ripe.net/apply/swprobe/ (shown in
# the plugin UI). The private key never leaves $STATE_DIR/etc.
if [ ! -f "$ATLAS_ETC/probe_key" ]; then
    ssh-keygen -t rsa -b 3072 -P '' -C "spr-atlas-$(hostname)" -f "$ATLAS_ETC/probe_key"
fi
chmod 600 "$ATLAS_ETC/probe_key"
chmod 644 "$ATLAS_ETC/probe_key.pub"

# Runtime dirs (equivalent of upstream's tmpfiles.d/ripe-atlas.conf).
mkdir -p "$ATLAS_RUN/pids" "$ATLAS_RUN/status"
mkdir -p "$ATLAS_SPOOL/data/new" "$ATLAS_SPOOL/data/out/ooq" "$ATLAS_SPOOL/data/out/ooq10" "$ATLAS_SPOOL/data/oneoff"
mkdir -p "$ATLAS_SPOOL/crons/main" "$ATLAS_SPOOL/crons/oneoff"
for i in $(seq 2 20); do mkdir -p "$ATLAS_SPOOL/crons/$i"; done

# The probe runs unprivileged; the bind-mounted dirs are created root-owned
# by docker, so fix ownership every start.
chown -R "$ATLAS_USER:$ATLAS_USER" "$ATLAS_ETC" "$ATLAS_SPOOL" "$ATLAS_RUN"
chmod 770 "$ATLAS_ETC"

# The plugin binary supervises the probe (see code/probe.go): it launches
# /scripts/run-probe.sh, captures its output, and exposes status/restart.
exec /spr_atlas_plugin
