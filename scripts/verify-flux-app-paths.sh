#!/usr/bin/env bash
set -euo pipefail

cluster_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
apps_root="${FLUX_APPS_REPO:-${cluster_root}/../flux-apps}"
kustomizations_dir="${cluster_root}/base/kustomizations/infra"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[flux-app-path-test] missing required command: %s\n' "$1" >&2
    exit 1
  }
}

fail() {
  printf '[flux-app-path-test] FAIL: %s\n' "$*" >&2
  exit 1
}

need kustomize
need yq

[ -d "$apps_root/apps" ] || fail "flux-apps repo not found at ${apps_root}; set FLUX_APPS_REPO"

found=0
while IFS= read -r file; do
  while IFS= read -r app_path; do
    [ -n "$app_path" ] || continue
    case "$app_path" in
      ./apps/*)
        app="${app_path#./apps/}"
        app="${app%%/*}"
        app_dir="${apps_root}/apps/${app}"
        [ -d "$app_dir" ] || fail "${file#${cluster_root}/}: references missing app ${app_path}"
        [ -f "${app_dir}/kustomization.yaml" ] || fail "${file#${cluster_root}/}: ${app_path} is missing kustomization.yaml"
        kustomize build "$app_dir" >/dev/null || fail "${file#${cluster_root}/}: ${app_path} failed kustomize build"
        printf '[flux-app-path-test] %s -> %s ok\n' "${file#${cluster_root}/}" "$app_path"
        found=$((found + 1))
        ;;
    esac
  done < <(yq -r '.. | select(has("path")?) | .path' "$file")
done < <(find "$kustomizations_dir" -type f -name '*.yaml' | sort)

[ "$found" -gt 0 ] || fail "no flux app paths found under ${kustomizations_dir}"
printf '[flux-app-path-test] verified %s app paths\n' "$found"
