#!/usr/bin/env bash
# Record what build $GITHUB_RUN_NUMBER published, from the artifacts in results/.
set -euo pipefail

{
  printf '| OS | Kubernetes | Tag | Digest |\n|---|---|---|---|\n'
  cat results/*/row.md
  printf '\n| Component | Version |\n|---|---|\n'
  # The Packer plugins and the scanners are not in the image
  sed -nE '/^(PACKER|SYFT|GRYPE)/d; s/^([A-Z_]+)_VERSION=(.+)/| \1 | \2 |/p' versions.env
} > notes.md
for dir in results/*/; do
  name=$(basename "$dir")
  mv "$dir/sbom.spdx.json" "${name#results-}.spdx.json"
  mv "$dir/grype.txt" "${name#results-}.grype.txt"
done
cat notes.md
gh release create "build-$GITHUB_RUN_NUMBER" --target "$GITHUB_SHA" --title "Build $GITHUB_RUN_NUMBER ($(date -u +%F))" \
  --notes-file notes.md --generate-notes ./*.spdx.json ./*.grype.txt
