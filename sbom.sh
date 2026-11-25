#!/usr/bin/env bash
# Write the SBOM and the known vulnerabilities of the built disk.
set -euo pipefail

. ./versions.env

dir=$(mktemp -d)
fetch() {
  curl -fsSL -o "$dir/$1.tgz" "https://github.com/anchore/$1/releases/download/$2/$1_${2#v}_linux_amd64.tar.gz"
  echo "$3  $dir/$1.tgz" | sha256sum -c -
  tar -xzf "$dir/$1.tgz" -C "$dir" "$1"
}
fetch syft "$SYFT_VERSION" "$SYFT_SHA256"
fetch grype "$GRYPE_VERSION" "$GRYPE_SHA256"

qemu-img convert -O raw "image-builder/images/capi/output/$OS-kube-$VERSION/$OS-kube-$VERSION" "$dir/disk.raw"
mkdir "$dir/root"
loop=$(sudo losetup -Pfr --show "$dir/disk.raw")
trap 'sudo umount "$dir/root" || true; sudo losetup -d "$loop"' EXIT
sudo mount -o ro,noload "${loop}p1" "$dir/root"

sudo SYFT_FILE_METADATA_SELECTION=none "$dir/syft" scan "dir:$dir/root" --base-path "$dir/root" \
  --source-name "$OS" --source-version "$VERSION" \
  -o spdx-json=sbom.spdx.json -o syft-json=sbom.syft.json
sudo chown "$(id -u)" sbom.*.json
# GitHub rejects attestations over 16 MB, and the file entries alone take most of that.
jq -c 'del(.files) | .relationships |= map(select(.spdxElementId + .relatedSpdxElement | contains("SPDXRef-File-") | not))' sbom.spdx.json > "$dir/spdx.json"
mv "$dir/spdx.json" sbom.spdx.json
jq -e --arg v "${VERSION#v}" 'any(.packages[]; .name == "kubelet" and (.versionInfo // "" | startswith($v + "-")))' sbom.spdx.json

# No --fail-on: most matches have no fix upstream yet.
"$dir/grype" sbom:sbom.syft.json -o json=grype.json -o table=grype.txt
jq -r '.matches | group_by(.vulnerability.severity)[] | "\(.[0].vulnerability.severity): \(length)"' grype.json
