#!/bin/bash
# Launch the RIPE Atlas probe main loop as the unprivileged ripe-atlas user.
#
# The container runs with no-new-privileges, so setuid bits and file
# capabilities are ignored. Instead the plugin supervisor (root) drops to
# ripe-atlas here and passes cap_net_raw down as an AMBIENT capability:
# ambient caps survive execve for unprivileged users even under
# no-new-privileges, which is exactly what the measurement binaries
# (evping/evtraceroute) need to open raw ICMP sockets. This is the only
# capability the probe tree keeps.
set -e

export HOME=/var/spool/ripe-atlas
export TZ=UTC
cd /var/spool/ripe-atlas

exec setpriv \
    --reuid ripe-atlas \
    --regid ripe-atlas \
    --init-groups \
    --inh-caps +net_raw \
    --ambient-caps +net_raw \
    /usr/sbin/ripe-atlas
