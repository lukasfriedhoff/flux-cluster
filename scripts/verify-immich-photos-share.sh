#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -eq 0 ]; then
  printf '[immich-photos-share-test] FAIL: pass one or more overlay paths\n' >&2
  exit 1
fi
overlays=("$@")

fail() {
  printf '[immich-photos-share-test] FAIL: %s\n' "$*" >&2
  exit 1
}

render_value() {
  local rendered=$1
  local key=$2
  awk -v key="$key" '$1 == key ":" { print $2; exit }' "$rendered" | tr -d '"'
}

for overlay in "${overlays[@]}"; do
  rendered="$(mktemp)"
  kustomize build "${repo_root}/${overlay}" >"$rendered"

  server="$(render_value "$rendered" photos_shared_nfs_server)"
  path="$(render_value "$rendered" photos_shared_nfs_path)"
  claim="$(render_value "$rendered" immich_photos_shared_claim_name)"
  pv="$(render_value "$rendered" immich_photos_shared_pv_name)"
  memes_server="$(render_value "$rendered" memes_shared_nfs_server)"
  memes_path="$(render_value "$rendered" memes_shared_nfs_path)"
  memes_claim="$(render_value "$rendered" immich_memes_shared_claim_name)"
  memes_pv="$(render_value "$rendered" immich_memes_shared_pv_name)"

  [ -n "$server" ] || fail "${overlay}: photos_shared_nfs_server is empty"
  [ "$path" != "/export" ] || fail "${overlay}: photos_shared_nfs_path still uses default /export"
  [ -n "$claim" ] || fail "${overlay}: immich_photos_shared_claim_name is empty"
  [ -n "$pv" ] || fail "${overlay}: immich_photos_shared_pv_name is empty"
  [ -n "$memes_server" ] || fail "${overlay}: memes_shared_nfs_server is empty"
  [ "$memes_path" != "/export" ] || fail "${overlay}: memes_shared_nfs_path still uses default /export"
  [ -n "$memes_claim" ] || fail "${overlay}: immich_memes_shared_claim_name is empty"
  [ -n "$memes_pv" ] || fail "${overlay}: immich_memes_shared_pv_name is empty"

  rm -f "$rendered"
  printf '[immich-photos-share-test] %s ok\n' "$overlay"
done
