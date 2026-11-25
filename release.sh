#!/usr/bin/env bash
# Record what build $GITHUB_RUN_NUMBER published, from the artifacts in results/.
set -euo pipefail

. ./versions.env

{
  printf '| OS | Kubernetes | Tag | Digest |\n|---|---|---|---|\n'
  cat results/*/row.md
  printf '\n| Component | Version |\n|---|---|\n'
  printf '| %s | %s |\n' containerd "$CONTAINERD_VERSION" runc "$RUNC_VERSION" crictl "$CRICTL_VERSION" "CNI plugins" "$CNI_VERSION"
  printf '\n| Image | Ubuntu base | Kernel | Critical | High | Medium | Low |\n|---|---|---|---:|---:|---:|---:|\n'
} > notes.md
for dir in results/*/; do
  name=$(basename "$dir") name=${name#results-}
  base=$(jq -r '.iso_url | capture("/release-(?<d>[0-9.]+)/").d' "qemu-${name%-v*}.json")
  kernel=$(grep -oE '[0-9]+\.[0-9.]+-[0-9]+-generic' "$dir/serial-flannel-worker.log" | tail -1)
  jq -r --arg image "$name" --arg base "$base" --arg kernel "$kernel" '[.matches[].vulnerability.severity] as $s
    | [$image, $base, $kernel, (("Critical", "High", "Medium", "Low") as $l | [$s[] | select(. == $l)] | length | tostring)]
    | "| " + join(" | ") + " |"' "$dir/grype.json" >> notes.md
  mv "$dir/sbom.spdx.json" "$name.spdx.json"
  mv "$dir/grype.txt" "$name.grype.txt"
done
cat >> notes.md <<END

Findings are raw grype matches, so one CVE counts once per package. [What stops a release](https://github.com/$GITHUB_REPOSITORY#vulnerabilities), and [how to verify an image](https://github.com/$GITHUB_REPOSITORY#verify).
END
cat notes.md
gh release create "build-$GITHUB_RUN_NUMBER" --target "$GITHUB_SHA" --title "Build $GITHUB_RUN_NUMBER ($(date -u +%F))" \
  --notes-file notes.md --generate-notes ./*.spdx.json ./*.grype.txt
