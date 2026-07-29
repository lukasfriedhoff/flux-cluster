#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if (($#)); then
  overlays=("$@")
else
  overlays=(homelab)
fi

fail() {
  echo "verify-matrix-bridge-history-import: $*" >&2
  exit 1
}

command -v jq >/dev/null || fail "jq is required"
command -v sops >/dev/null || fail "sops is required"
command -v yq >/dev/null || fail "yq is required"

umask 077
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

for overlay in "${overlays[@]}"; do
  whatsapp_secret="$repo_root/overlays/$overlay/secrets/matrix-whatsapp-config.yaml"
  signal_secret="$repo_root/overlays/$overlay/secrets/matrix-signal-config.yaml"
  whatsapp_config="$tmpdir/$overlay-whatsapp.json"
  signal_config="$tmpdir/$overlay-signal.json"

  [[ -f "$whatsapp_secret" ]] || fail "missing WhatsApp secret for overlay '$overlay'"
  [[ -f "$signal_secret" ]] || fail "missing Signal secret for overlay '$overlay'"

  sops -d --extract '["stringData"]["config.yaml"]' "$whatsapp_secret" |
    yq . >"$whatsapp_config"
  sops -d --extract '["stringData"]["config.yaml"]' "$signal_secret" |
    yq . >"$signal_config"

  jq -e '
    .network.history_sync.max_initial_conversations == -1 and
    .network.history_sync.request_full_sync == true and
    .network.history_sync.full_sync_config.days_limit == 1095 and
    .network.history_sync.media_requests.auto_request_media == true and
    .backfill.enabled == true and
    .backfill.max_initial_messages >= 100000 and
    .backfill.max_catchup_messages >= 10000 and
    .backfill.threads.max_initial_messages >= 100000 and
    .backfill.queue.enabled == false
  ' "$whatsapp_config" >/dev/null ||
    fail "$overlay: WhatsApp full history import safeguards are incomplete"

  jq -e '
    .backfill.enabled == true and
    .backfill.max_initial_messages >= 100000 and
    .backfill.max_catchup_messages >= 10000 and
    .backfill.threads.max_initial_messages >= 100000 and
    .backfill.queue.enabled == false
  ' "$signal_config" >/dev/null ||
    fail "$overlay: Signal full history import safeguards are incomplete"

  echo "$overlay: Signal and WhatsApp history import safeguards passed"
done

echo "Matrix bridge history import checks passed."
