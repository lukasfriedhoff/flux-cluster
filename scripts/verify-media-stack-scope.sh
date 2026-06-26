#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
branch="$(git -C "$repo_root" branch --show-current)"
root_kustomization="$repo_root/base/kustomizations/kustomization.yaml"

fail() {
  echo "verify-media-stack-scope: $*" >&2
  exit 1
}

media_secret_pattern='jellyfin-sso|media-protonvpn|arr-api-keys|jellyfin-e2e-auth|jellyseerr-e2e-auth|prowlarr-private-trackers'
media_config_pattern='(^|[[:space:]])(media_force|arr_|jellyfin_|jellyseerr_|prowlarr_|qbittorrent_|qbit_|metube_|rockethd_)'

case "$branch" in
  main)
    grep -Fq 'infra/media.yaml' "$root_kustomization" || fail "main must include the media-app Kustomization"
    grep -Eq "$media_secret_pattern" "$repo_root/overlays/homelab/secrets/kustomization.yaml" \
      || fail "homelab must still include prod media secrets"
    ;;
  testing|develop)
    if grep -Fq 'infra/media.yaml' "$root_kustomization"; then
      fail "$branch must not include the media-app Kustomization"
    fi
    for overlay in testing-srv3 staging-3vm; do
      secrets_file="$repo_root/overlays/$overlay/secrets/kustomization.yaml"
      if grep -Eq "$media_secret_pattern" "$secrets_file"; then
        fail "$overlay still deploys media-only secrets"
      fi
      if grep -Eq "$media_config_pattern" "$repo_root/overlays/$overlay/cluster-patch.yaml"; then
        fail "$overlay still has media-only substitution keys"
      fi
    done
    ;;
  *)
    echo "verify-media-stack-scope: skipping branch '$branch'"
    ;;
esac
