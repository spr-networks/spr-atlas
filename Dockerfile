# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
ARG ALPINE_REF=alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
ARG UBUNTU_REF=ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90
ARG NODE_REF=node:18@sha256:c6ae79e38498325db67193d391e6ec1d224d96c693a8a4d943498556716d3783
ARG CONTAINER_TEMPLATE_REF=ghcr.io/spr-networks/container_template@sha256:869ada7b121e9a0c552674042d32e801da3c4d04145638d9e722918c6377e65f
ARG SOURCE_DATE_EPOCH

FROM ${ALPINE_REF} AS cacerts

# ---------------------------------------------------------------------------
# Go plugin backend
# ---------------------------------------------------------------------------
FROM ${UBUNTU_REF} AS builder
ENV DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_SNAPSHOT=20260601T000000Z
ARG GO_VERSION=1.25.12
ARG GO_SHA256_AMD64=234828b7a89e0e303d2556310ee549fbcf253d28de937bac3da13d6294262ac1
ARG GO_SHA256_ARM64=8b5884aef89600aef5b0b051fb971f11f49bb996521e911f30f02a66884f7bd2
ARG TARGETARCH
COPY --from=cacerts /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN set -eux; \
    printf 'Types: deb\nURIs: https://snapshot.ubuntu.com/ubuntu/%s\nSuites: noble noble-updates noble-security\nComponents: main restricted universe multiverse\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' "${UBUNTU_SNAPSHOT}" > /etc/apt/sources.list.d/ubuntu.sources; \
    printf 'APT::Install-Recommends "false";\nAcquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99reproducible
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git wget && rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) GO_SHA256="${GO_SHA256_AMD64}";; \
      arm64) GO_SHA256="${GO_SHA256_ARM64}";; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1;; \
    esac; \
    wget -q "https://dl.google.com/go/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz"; \
    echo "${GO_SHA256}  go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" | sha256sum -c -; \
    tar -C /usr/local -xzf "go${GO_VERSION}.linux-${TARGETARCH}.tar.gz"; \
    rm "go${GO_VERSION}.linux-${TARGETARCH}.tar.gz"
ENV PATH="/usr/local/go/bin:${PATH}" GOTOOLCHAIN=local
WORKDIR /code
COPY code/ /code/
RUN --mount=type=tmpfs,target=/root/go/ go build -trimpath -ldflags "-s -w" -o /spr_atlas_plugin /code/

# ---------------------------------------------------------------------------
# RIPE Atlas software probe, built from source at a pinned release commit
# ---------------------------------------------------------------------------
FROM ${UBUNTU_REF} AS atlas-builder
ENV DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_SNAPSHOT=20260601T000000Z
# Latest production release tag (5120) pinned by full commit hash.
ARG ATLAS_VERSION=5120
ARG ATLAS_COMMIT=0afb77a2987032181a776251966a5dd0ae450cce
COPY --from=cacerts /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN set -eux; \
    printf 'Types: deb\nURIs: https://snapshot.ubuntu.com/ubuntu/%s\nSuites: noble noble-updates noble-security\nComponents: main restricted universe multiverse\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' "${UBUNTU_SNAPSHOT}" > /etc/apt/sources.list.d/ubuntu.sources; \
    printf 'APT::Install-Recommends "false";\nAcquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99reproducible
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git build-essential autoconf automake libtool libssl-dev \
    && rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache
# Fetch exactly the pinned commit (no branches/tags trusted at build time).
RUN set -eux; \
    mkdir -p /src/atlas; cd /src/atlas; \
    git init .; \
    git remote add origin https://github.com/RIPE-NCC/ripe-atlas-software-probe.git; \
    git fetch --depth 1 origin "${ATLAS_COMMIT}"; \
    git checkout --detach "${ATLAS_COMMIT}"; \
    test "$(git rev-parse HEAD)" = "${ATLAS_COMMIT}"; \
    test "$(cat VERSION)" = "${ATLAS_VERSION}"
# Build layout matches the upstream Debian packaging (FHS, >= 5090):
#   /usr/sbin/ripe-atlas               main loop
#   /usr/libexec/ripe-atlas/           scripts + measurement busybox applets
#   /usr/share/ripe-atlas/             static data (known_hosts.reg, ...)
#   /etc/ripe-atlas/                   mode, reg_servers, ssh probe key
#   /var/spool/ripe-atlas/             measurement spool (probe HOME)
# chown/setcap are skipped here (users don't exist in the build stage);
# ownership is fixed in the runtime stage / scripts/startup.sh, and raw-socket
# capability is granted at runtime via ambient caps (see scripts/startup.sh).
RUN set -eux; cd /src/atlas; \
    autoreconf -iv; \
    ./configure \
      --prefix=/usr \
      --sysconfdir=/etc \
      --localstatedir=/var \
      --runstatedir=/run \
      --with-install-mode=probe \
      --with-user=ripe-atlas \
      --with-group=ripe-atlas \
      --with-measurement-user=ripe-atlas \
      --with-shell-fixup=/bin/bash \
      --disable-systemd \
      --disable-chown \
      --disable-setcap-install; \
    make; \
    make install DESTDIR=/atlas

# ---------------------------------------------------------------------------
# Frontend (single self-contained index.html served by the Go backend)
# ---------------------------------------------------------------------------
FROM ${NODE_REF} AS builder-ui
WORKDIR /app
COPY frontend ./
RUN --mount=type=tmpfs,target=/root/.cache \
    --mount=type=tmpfs,target=/app/node_modules \
    yarn install --frozen-lockfile --network-timeout 86400000 && yarn run bundle

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM ${CONTAINER_TEMPLATE_REF}
ENV DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_SNAPSHOT=20260601T000000Z
# Runtime deps of the probe (mirrors upstream ripe-atlas-common Depends):
#  bash (probe scripts), openssh-client (registration + controller channel),
#  net-tools + iproute2 (ifconfig/arp/route/ip used by the main loop),
#  psmisc (killall), procps (free/pkill). util-linux provides setpriv.
RUN set -eux; \
    printf 'Types: deb\nURIs: https://snapshot.ubuntu.com/ubuntu/%s\nSuites: noble noble-updates noble-security\nComponents: main restricted universe multiverse\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' "${UBUNTU_SNAPSHOT}" > /etc/apt/sources.list.d/ubuntu.sources; \
    printf 'APT::Install-Recommends "false";\nAcquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99reproducible; \
    apt-get update && apt-get install -y --no-install-recommends \
      bash openssh-client net-tools iproute2 psmisc procps util-linux \
    && rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache; \
    rm -f /etc/apt/sources.list.d/ubuntu.sources
# Unprivileged user the probe runs as (fixed uid/gid for reproducibility).
RUN groupadd -r -g 900 ripe-atlas && \
    useradd -r -u 900 -g 900 -d /var/spool/ripe-atlas -s /usr/sbin/nologin ripe-atlas
COPY --from=atlas-builder /atlas/ /
# /etc/ripe-atlas is bind-mounted from /state/plugins/spr-atlas/etc at runtime
# (so the probe key survives rebuilds); keep the installed defaults as a seed.
RUN mkdir -p /usr/share/ripe-atlas-defaults && \
    cp -a /etc/ripe-atlas/. /usr/share/ripe-atlas-defaults/
COPY scripts /scripts/
COPY --from=builder /spr_atlas_plugin /
COPY --from=builder-ui /app/build/ /ui/

ENTRYPOINT ["/scripts/startup.sh"]
