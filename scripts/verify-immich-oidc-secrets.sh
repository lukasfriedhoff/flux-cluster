#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -eq 0 ]; then
  overlays=(overlays/testing-srv3 overlays/staging-3vm overlays/homelab)
else
  overlays=("$@")
fi

fail() {
  printf '[immich-oidc-secret-test] FAIL: %s\n' "$*" >&2
  exit 1
}

extract_secret() {
  local file=$1
  local query=$2
  local output=$3
  sops -d --extract "$query" "$file" >"$output"
}

check_plain_client_secret() {
  local overlay=$1
  local file=$2
  local key=$3
  local output=$4

  extract_secret "$file" '["stringData"]["IMMICH_OIDC_CLIENT_SECRET"]' "$output"
  if [ ! -s "$output" ]; then
    fail "${overlay}: ${key} IMMICH_OIDC_CLIENT_SECRET is empty"
  fi

  local bytes
  bytes=$(wc -c <"$output" | tr -d ' ')
  if [ "$bytes" -gt 72 ]; then
    fail "${overlay}: ${key} IMMICH_OIDC_CLIENT_SECRET looks like an Authelia hash (${bytes} bytes), not app plaintext"
  fi

  local first_char
  first_char=$(head -c 1 "$output" || true)
  if [ "$first_char" = '$' ]; then
    fail "${overlay}: ${key} IMMICH_OIDC_CLIENT_SECRET starts like a password hash"
  fi
}

for overlay in "${overlays[@]}"; do
  overlay_path="${repo_root}/${overlay}"
  [ -d "$overlay_path" ] || fail "overlay not found: ${overlay}"

  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  immich_secret="${overlay_path}/secrets/immich-secrets.yaml"
  photos_secret="${overlay_path}/secrets/immich-photos-secrets.yaml"
  [ -f "$immich_secret" ] && check_plain_client_secret "$overlay" "$immich_secret" immich "$tmpdir/immich-client-secret"
  [ -f "$photos_secret" ] && check_plain_client_secret "$overlay" "$photos_secret" immich-photos "$tmpdir/photos-client-secret"

  authelia_secret="${overlay_path}/secrets/authelia-oidc.yaml"
  if [ -f "$authelia_secret" ] && [ -f "$immich_secret" ]; then
    extract_secret "$authelia_secret" '["stringData"]["identity_providers.oidc.client.immich.secret"]' "$tmpdir/authelia-immich-secret"
    if cmp -s "$tmpdir/authelia-immich-secret" "$tmpdir/immich-client-secret"; then
      fail "${overlay}: Immich app secret equals Authelia stored secret; app must use client plaintext"
    fi
  fi

  rm -rf "$tmpdir"
  trap - EXIT
  printf '[immich-oidc-secret-test] %s ok\n' "$overlay"
done
