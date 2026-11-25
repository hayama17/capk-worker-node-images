#!/usr/bin/env bash
# Build the container disk for $OS (e.g. ubuntu-2404-minimal) and $VERSION (e.g. v1.37.2) with image-builder.
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

# The base image follows Ubuntu's latest release, so trust the signature rather than a pinned digest
base=$(jq -r .iso_url "qemu-$OS.json")
sums=$(mktemp -d)
curl -fsSL --output-dir "$sums" -O "${base%/*}/SHA256SUMS" -O "${base%/*}/SHA256SUMS.gpg"
gpgv --keyring /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg "$sums/SHA256SUMS.gpg" "$sums/SHA256SUMS"
sha=$(awk -v f="${base##*/}" '{sub(/^\*/, "", $2)} $2==f{print $1}' "$sums/SHA256SUMS")
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "no checksum for $base" >&2; exit 1; }

git -C image-builder apply ../image-builder.patch
cp "qemu-$OS.json" image-builder/images/capi/packer/qemu/
cp -r roles/* image-builder/images/capi/ansible/roles/
cd image-builder/images/capi
export PATH="$HOME/.local/bin:$PATH"
export QEMU_BUILD_NAMES=qemu-$OS
export PACKER_FLAGS="--var kubernetes_semver=$VERSION --var kubernetes_series=$series --var kubernetes_deb_version=$deb --var iso_checksum=$sha"
# Packer looks up plugins anonymously, which shared runners often exhaust
make deps-qemu || { sleep 300; make deps-qemu; }
make "build-kubevirt-qemu-$OS"
ls -lh output/*/
docker image ls
