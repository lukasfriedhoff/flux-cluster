#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
overlays=("${@:-}")
if [ "${#overlays[@]}" -eq 0 ]; then
  overlays=(overlays/testing-srv3 overlays/staging-3vm overlays/homelab)
fi

fail() {
  printf '[media-policy-test] FAIL: %s\n' "$*" >&2
  exit 1
}

for overlay in "${overlays[@]}"; do
  rendered="$(mktemp)"
  kustomize build "${repo_root}/${overlay}" >"$rendered"

  if grep -q 'qbittorrent_default_seed_ratio:' "$rendered"; then
    rm -f "$rendered"
    fail "${overlay}: legacy qbittorrent_default_seed_ratio is still rendered"
  fi

  prowlarr_seed_ratio="$(yq '.data.prowlarr_default_seed_ratio // ""' "$rendered" 2>/dev/null | head -n1 | tr -d '"' || true)"
  if [ -n "$prowlarr_seed_ratio" ]; then
    rm -f "$rendered"
    fail "${overlay}: prowlarr_default_seed_ratio must be empty to avoid ratio-stop inheritance, got '${prowlarr_seed_ratio}'"
  fi

  rm -f "$rendered"
  printf '[media-policy-test] %s ok\n' "$overlay"
done
