#!/bin/bash
# Build and register the dedicated KVM/libkrun runtime used by spr-atlas.
#
# Tested on Debian 13 arm64. This installs libkrunfw + libkrun globally, but
# installs the patched crun binary under its own krun-atlas runtime name so a
# general-purpose krun installation remains untouched.
set -euo pipefail

LIBKRUNFW_VERSION=5.5.0
LIBKRUNFW_SHA256=b04c9a5520a1ea52b5b35d87559566872246145961c4b6978034c9b9be54b89b
LIBKRUN_VERSION=1.19.4
LIBKRUN_COMMIT=728df8125077d0db44265f6e997c72b81b65c015
CRUN_VERSION=1.28
CRUN_SHA256=eb8fe73ffe44d868b14bb94fa6c295bd57e8bf023de43b61579da826c07cc406
RUST_VERSION=1.97.1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIBKRUN_PATCHES=(
    "$SCRIPT_DIR/patches/0006-libkrun-reliable-dhcp.patch"
)
CRUN_PATCHES=(
    "$SCRIPT_DIR/patches/0002-crun-limit-passt-forwarding.patch"
    "$SCRIPT_DIR/patches/0003-crun-direct-tap.patch"
)
BUILD_DIR="$(mktemp -d /tmp/spr-krun-build.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

if [ "$(uname -m)" != "aarch64" ]; then
    echo "setup_krun_runtime.sh currently supports aarch64 only" >&2
    exit 1
fi
if [ ! -c /dev/kvm ]; then
    echo "/dev/kvm is not available; KVM must work before installing libkrun" >&2
    exit 1
fi
for patch in "${LIBKRUN_PATCHES[@]}" "${CRUN_PATCHES[@]}"; do
    if [ ! -f "$patch" ]; then
        echo "missing crun patch: $patch" >&2
        exit 1
    fi
done

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    build-essential \
    ca-certificates \
    curl \
    gettext \
    git \
    iproute2 \
    jq \
    libcap-dev \
    libclang-dev \
    libjson-c-dev \
    libseccomp-dev \
    libsystemd-dev \
    libtool \
    libyajl-dev \
    patchelf \
    pkg-config

if ! command -v rustup >/dev/null 2>&1; then
    # Debian's rustup package replaces the distribution's older rustc/cargo
    # packages, which are too old for this pinned libkrun release.
    sudo apt-get install -y --no-install-recommends rustup
fi

rustup toolchain install "$RUST_VERSION" --profile minimal
rustup default "$RUST_VERSION"
export PATH="$HOME/.cargo/bin:$PATH"

cd "$BUILD_DIR"
curl --fail --location --show-error \
    --output libkrunfw-aarch64.tgz \
    "https://github.com/libkrun/libkrunfw/releases/download/v${LIBKRUNFW_VERSION}/libkrunfw-aarch64.tgz"
printf '%s  %s\n' "$LIBKRUNFW_SHA256" libkrunfw-aarch64.tgz | sha256sum --check -
sudo tar -C /usr/local -xzf libkrunfw-aarch64.tgz

git init --quiet libkrun
git -C libkrun remote add origin https://github.com/containers/libkrun.git
git -C libkrun fetch --quiet --depth 1 origin "$LIBKRUN_COMMIT"
git -C libkrun checkout --quiet --detach FETCH_HEAD
test "$(git -C libkrun rev-parse HEAD)" = "$LIBKRUN_COMMIT"
grep -Fxq "FULL_VERSION=$LIBKRUN_VERSION" libkrun/Makefile
for patch in "${LIBKRUN_PATCHES[@]}"; do
    git -C libkrun apply --check "$patch"
    git -C libkrun apply "$patch"
done
make -C libkrun -j"${MAKE_JOBS:-$(nproc)}" NET=1
sudo make -C libkrun NET=1 install

printf '%s\n' /usr/local/lib64 | sudo tee /etc/ld.so.conf.d/libkrun.conf >/dev/null
sudo ldconfig

curl --fail --location --show-error \
    --output "crun-${CRUN_VERSION}.tar.gz" \
    "https://github.com/containers/crun/releases/download/${CRUN_VERSION}/crun-${CRUN_VERSION}.tar.gz"
printf '%s  %s\n' "$CRUN_SHA256" "crun-${CRUN_VERSION}.tar.gz" | sha256sum --check -
tar -xzf "crun-${CRUN_VERSION}.tar.gz"
cd "crun-${CRUN_VERSION}"
for patch in "${CRUN_PATCHES[@]}"; do
    git apply --check "$patch"
    git apply "$patch"
done
PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig \
CPPFLAGS=-I/usr/local/include \
LDFLAGS=-L/usr/local/lib64 \
    ./configure --prefix=/usr/local --with-libkrun
make -j"${MAKE_JOBS:-$(nproc)}"
sudo install -d -m 0755 /usr/local/libexec/krun-atlas
sudo install -m 0755 crun /usr/local/libexec/krun-atlas/krun

DAEMON_JSON=/etc/docker/daemon.json
DAEMON_TMP="$(mktemp)"
if [ -f "$DAEMON_JSON" ]; then
    jq '.runtimes["krun-atlas"] = {
        "path": "/usr/local/libexec/krun-atlas/krun"
    }' "$DAEMON_JSON" > "$DAEMON_TMP"
else
    jq --null-input '{
        "runtimes": {
            "krun-atlas": {
                "path": "/usr/local/libexec/krun-atlas/krun"
            }
        }
    }' > "$DAEMON_TMP"
fi
if [ -f "$DAEMON_JSON" ]; then
    sudo cp -a "$DAEMON_JSON" \
        "${DAEMON_JSON}.bak.krun-atlas.$(date +%Y%m%d%H%M%S)"
fi
sudo install -m 0644 "$DAEMON_TMP" "$DAEMON_JSON"
rm -f "$DAEMON_TMP"

# Docker supports reloading runtime definitions; no host or daemon restart is
# needed, so existing containers stay up.
sudo systemctl reload docker
if ! sudo docker info --format '{{json .Runtimes}}' |
    grep -Fq '"krun-atlas"'; then
    echo "Docker did not expose the krun-atlas runtime after reload" >&2
    exit 1
fi

echo "krun-atlas installed successfully"
echo "No reboot or Docker restart was performed."
