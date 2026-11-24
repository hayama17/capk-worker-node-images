#!/usr/bin/env bash
# Build the container disk for $VERSION (e.g. v1.37.2) with image-builder.
set -euo pipefail

[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid version: $VERSION" >&2; exit 1; }
semver=${VERSION#v}
series=${VERSION%.*}
deb=$(curl -fsSL "https://pkgs.k8s.io/core:/stable:/$series/deb/Packages" |
  awk -v v="$semver" '/^Package: /{p=$2} /^Version: /{if (p=="kubelet" && index($2, v "-")==1) d=$2} END{print d}')
[[ -n "$deb" ]] || { echo "no kubelet package for $VERSION" >&2; exit 1; }

sudo apt-get update -q
sudo apt-get install -y -q qemu-system-x86 qemu-utils xorriso
sudo chmod 666 /dev/kvm

cp qemu-ubuntu-2604-minimal.json image-builder/images/capi/packer/qemu/
cd image-builder/images/capi
export PATH="$HOME/.local/bin:$PATH"
export QEMU_BUILD_NAMES=qemu-ubuntu-2604-minimal
export PACKER_FLAGS="--var kubernetes_semver=$VERSION --var kubernetes_series=$series --var kubernetes_deb_version=$deb"
make deps-qemu
make build-kubevirt-qemu-ubuntu-2604-minimal
ls -lh output/*/
docker image ls
