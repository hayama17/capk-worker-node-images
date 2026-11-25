#!/usr/bin/env bash
# Write the SBOM and the known vulnerabilities of the disk inside container disk $1.
set -euo pipefail

SYFT=1.57.2 SYFT_SHA=ad92bd3ec1b94a3df01d4d0aec199afa9c42b72e86da436ff5f837914d32706b
GRYPE=0.122.1 GRYPE_SHA=f1ba7e2917ee1395618de20a98da0aa7c0fb1788927797651047c50502a37538

dir=$(mktemp -d)
fetch() {
  curl -fsSL -o "$dir/$1.tgz" "https://github.com/anchore/$1/releases/download/v$2/$1_$2_linux_amd64.tar.gz"
  echo "$3  $dir/$1.tgz" | sha256sum -c -
  tar -xzf "$dir/$1.tgz" -C "$dir" "$1"
}
fetch syft "$SYFT" "$SYFT_SHA"
fetch grype "$GRYPE" "$GRYPE_SHA"
sudo apt-get update -q
sudo apt-get install -y -q qemu-utils

# Image scanners only see one qcow2 file, so scan the file system inside it.
id=$(docker create "$1" none)
docker cp "$id:/disk/image.qcow2" "$dir/disk.qcow2"
docker rm "$id" >/dev/null
qemu-img convert -O raw "$dir/disk.qcow2" "$dir/disk.raw"
rm "$dir/disk.qcow2"
mkdir "$dir/root"
loop=$(sudo losetup -Pfr --show "$dir/disk.raw")
trap 'sudo umount "$dir/root" || true; sudo losetup -d "$loop"' EXIT
sudo mount -o ro,noload "${loop}p1" "$dir/root"

# GitHub rejects attestations over 16 MB, so leave out the file list.
sudo SYFT_FILE_METADATA_SELECTION=none "$dir/syft" scan "dir:$dir/root" --base-path "$dir/root" \
  --source-name "${1%%[:@]*}" --source-version "$VERSION" \
  -o spdx-json=sbom.spdx.json -o syft-json=sbom.syft.json
sudo chown "$(id -u)" sbom.*.json
ls -lh sbom.*.json
jq -e --arg v "${VERSION#v}" 'any(.packages[]; .name == "kubelet" and (.versionInfo // "" | startswith($v + "-")))' sbom.spdx.json

# No --fail-on: the images still carry control plane images that workers never run.
"$dir/grype" sbom:sbom.syft.json -o json=grype.json -o table=grype.txt
jq -r '.matches | group_by(.vulnerability.severity)[] | "\(.[0].vulnerability.severity): \(length)"' grype.json
