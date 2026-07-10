# spr-atlas

<img width="850" alt="spr-atlas UI preview" src="docs/screenshot.png" />

Run a [RIPE Atlas](https://atlas.ripe.net/) **software probe** on your SPR
router. RIPE Atlas is the RIPE NCC's global internet measurement network:
hosting a probe contributes ping/traceroute/DNS/TLS measurements from your
network vantage point and earns you credits to run your own measurements.

## About

The plugin builds the official
[RIPE-NCC/ripe-atlas-software-probe](https://github.com/RIPE-NCC/ripe-atlas-software-probe)
from source at a pinned release, runs it in an isolated container on its own
`spr-atlas` bridge, and adds a small Go backend + React UI (rendered by SPR as
an iframe under Plugins) for status, registration and logs.

On first start the probe generates an RSA ssh keypair — its permanent
identity. You (the admin) register the **public** key at
<https://atlas.ripe.net/apply/swprobe/>; the UI shows the key with a copy
button and step-by-step instructions. Once RIPE approves the application the
probe connects to its assigned controller automatically (outbound ssh over
port 443). The key is stored under `state/plugins/spr-atlas/etc/` so it
survives container rebuilds and plugin upgrades.

## Features

- RIPE Atlas software probe (latest production release, built from source,
  pinned by commit hash)
- IPv4 startup reachability check for the plugin's IPv4-only container bridge
- Registration card: probe public key + fingerprint, copy button, link to the
  RIPE application form
- Status card: probe process state, uptime, controller connection heuristic,
  assigned controller, firmware version
- Sanitized probe log tail in the UI (severity-tinted, optional auto-refresh)
- Probe restart behind a confirmation dialog
- Contributes the assigned Atlas controller to SPR's topology view
  (`HasTopology` + `GET /topology`)
- Probe identity persisted under `state/plugins/spr-atlas/` (survives
  rebuilds)

## UI Setup

1. In the SPR UI, go to **Plugins** → `+ New Plugin` and add
   `https://github.com/spr-networks/spr-atlas`.
2. Open **spr-atlas** at the bottom of the left-hand menu.
3. Copy the probe public key from the Registration card and submit it at
   <https://atlas.ripe.net/apply/swprobe/> (requires a free RIPE NCC Access
   account; software probes are always public probes).
4. Wait for approval — the status dot turns green once the probe is connected
   to a controller. No further configuration is needed.

## Command Line Setup

```bash
cd /home/spr/super/plugins/
git clone https://github.com/spr-networks/spr-atlas
cd spr-atlas
./install.sh   # prompts for the SUPER dir and an SPR API token
```

The script builds the image, starts the container, grants the `spr-atlas`
bridge `wan`+`dns` policies via the SPR API, and prints the probe public key
to register.

## API

All endpoints are served over the plugin unix socket
(`/state/plugins/spr-atlas/socket`) and proxied by SPR under
`/plugins/spr-atlas/`.

| Method | Path       | Description                                                                                             |
| ------ | ---------- | ------------------------------------------------------------------------------------------------------- |
| GET    | `/status`  | Probe state: `Running`, `PID`, `UptimeSeconds`, `Restarts`, `Registered`, `Connected`, `ControllerHost`, `KeyExists`, `Fingerprint`, `Version` |
| GET    | `/key`     | Probe **public** key + SHA256 fingerprint + registration URL (public keys are safe to show)              |
| POST   | `/restart` | Restart the probe process tree                                                                           |
| GET    | `/logs`    | Sanitized tail of the probe log, `{"Lines": [...]}`; optional `?lines=1..1000` (default 200)            |
| GET    | `/topology` | Plugin topology graph `{"Nodes": [...], "Edges": [...]}` merged into SPR's topology view (see below)   |

`Connected` is a heuristic from the probe's own state files: registration
state present (`reginit.vol`) and the ssh keepalive session to the controller
alive (`con_keep_pid.vol`).

### Topology

The plugin sets `HasTopology` in `plugin.json` and contributes a small graph
to SPR's router topology view: a root anchor node (`ConnType: "atlas"`) plus,
once the probe is registered, one node for the assigned RIPE Atlas controller
(`Kind: "controller"`, named after the controller host, online while the
keepalive ssh session is up) connected to root by a `wan`-layer edge. When the
probe is unregistered or down the graph is just the root anchor.

## Configuration

There is nothing to configure for a standard probe. Probe state lives in:

| Host path                              | In container            | Purpose                                    |
| -------------------------------------- | ----------------------- | ------------------------------------------ |
| `state/plugins/spr-atlas/etc/`         | `/etc/ripe-atlas`       | probe ssh keypair, mode, reg servers       |
| `state/plugins/spr-atlas/spool/`       | `/var/spool/ripe-atlas` | measurement spool/crontabs                 |
| `state/plugins/spr-atlas/log/`         | —                       | captured probe log (size-capped)           |
| `configs/plugins/spr-atlas/api-token`  | `/configs/spr-atlas`    | SPR API token written at install (unused by the backend today) |

To reset the probe identity (new probe application), stop the plugin and
delete `state/plugins/spr-atlas/etc/probe_key*`; a new keypair is generated on
the next start.

## Security model

- **No published ports.** The backend listens only on the plugin unix socket;
  SPR proxies the UI/API. The probe makes **outbound-only** connections:
  ssh to RIPE registration/controller servers on port 443, plus the
  measurements themselves.
- **Own bridge network** (`spr-atlas`) with SPR policies `wan` and `dns` only —
  the container cannot reach LAN devices or the SPR API.
- **`cap_add: NET_RAW` only.** The measurement engine (busybox applets
  `evping`/`evtraceroute`) opens raw ICMP sockets. `NET_ADMIN` is *not*
  granted: the probe never creates interfaces, routes or firewall rules.
- **Unprivileged probe.** The container starts as root only to fix ownership
  of mounted state dirs, then runs the whole probe tree as the `ripe-atlas`
  user with a single ambient capability (`cap_net_raw`) via `setpriv`
  (`scripts/run-probe.sh`). `no-new-privileges:true` is set, so setuid
  binaries and file capabilities are inert inside the container.
- **Private key stays private.** `probe_key` is `0600`, owned by `ripe-atlas`,
  and no API endpoint reads it — `GET /key` reads only `probe_key.pub` and
  validates it looks like an OpenSSH public key before serving. Log output is
  sanitized (control characters stripped, key material redacted) before it is
  stored or served.
- The probe's built-in telnetd binds `127.0.0.1:2023` *inside* the container
  namespace only (upstream behaviour; unreachable from anywhere else).

## Upstream project

- Source: <https://github.com/RIPE-NCC/ripe-atlas-software-probe> (GPL-2.0 for
  the probe/busybox code — built from the pinned upstream commit with one
  local patch that makes the pre-registration ping use IPv4; this plugin's own
  code is MIT)
- Docs: <https://atlas.ripe.net/docs/howtos/software-probes.html>
- Registration: <https://atlas.ripe.net/apply/swprobe/>

## Reproducible builds

Every build input is pinned in `reproducible.env`: base images by digest,
apt packages via `snapshot.ubuntu.com`, the Go toolchain by version + sha256,
and the RIPE Atlas source by release tag + **full commit hash**
(`ATLAS_VERSION` / `ATLAS_COMMIT`, verified against `git rev-parse HEAD` and
the upstream `VERSION` file at build time). The local IPv4 startup-check patch
is applied with `git apply --check`, so an incompatible upstream change fails
the build instead of silently producing a different image.

- `./build_docker_compose.sh` — reproducible local build (buildx +
  `rewrite-timestamp`, `SOURCE_DATE_EPOCH=0`)
- `./update-pins.sh` — re-resolve all pins (image digests, latest Go 1.25.x,
  latest Atlas *production* release tag — upstream tags divisible by 10 — and
  its commit hash) and sync the Dockerfile ARG defaults
