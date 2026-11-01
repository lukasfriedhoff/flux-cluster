#!/usr/bin/env bash
# Read-only preflight for the mautrix-whatsapp v26.08+ LID DM migration.
#
# On every start (>= v26.08) the bridge re-IDs each phone-number DM portal to
# its LID *synchronously* before connecting, and for every portal that has a
# Matrix room it sends three member events: the PN ghost leaves, the bridge bot
# invites the LID ghost, the LID ghost joins. ANY failure aborts startup
# ("failed to start network connector: failed to re-ID <pn> to <lid>: ...") and
# the pod crash-loops (2026-08-07 incident). The portal row is re-keyed before
# the member events are sent, so each crash "consumes" one broken portal.
#
# Rooms retained from the 2026-08 server-name rename hold the OLD-domain ghost,
# not @whatsapp_<pn>:<server>, so the PN-ghost leave is rejected (not in room)
# and in many of them the current bot has no power or is not joined either.
#
# This script classifies every PN DM portal that will be touched:
#   migratable = PN ghost joined AND bot joined AND bot power >= invite level
#   blocked    = everything else (will crash the bridge)
# and writes, for the blocked ones, a detach SQL file that clears portal.mxid.
# With mxid empty the bridge's own ReIDPortal path just deletes the PN portal
# row (no Matrix calls); the old room stays as read-only history and the next
# message from that contact opens a fresh LID DM room. The script itself
# changes nothing; apply the SQL only with the bridge scaled to 0.
set -euo pipefail
set +x

ctx="${KUBE_CONTEXT:-homelab-prod}"
ns="${NAMESPACE:-matrix}"
server_name="${SERVER_NAME:-h4xx.io}"
bot="${BRIDGE_USER_ID:-@whatsappbot:${server_name}}"
out_dir="${1:-.}"

k() { kubectl --context "$ctx" -n "$ns" "$@"; }
primary() { k get cluster "$1" -o jsonpath='{.status.currentPrimary}'; }

wa_primary="$(primary whatsappdb)"
syn_primary="$(primary synapsedb)"
[[ -n "$wa_primary" && -n "$syn_primary" ]] || { echo "cannot resolve CNPG primaries" >&2; exit 1; }
mkdir -p "$out_dir"
rooms_file="$out_dir/wa-lid-pn-rooms.tsv"
blocked_file="$out_dir/wa-lid-blocked-rooms.txt"
sql_file="$out_dir/wa-lid-detach-blocked.sql"

# room_id <TAB> PN ghost MXID, for PN DM portals with a room and a known LID.
k exec "$wa_primary" -c postgres -- psql -U postgres -d mautrixwhatsapp -At -F $'\t' -c "
  SELECT p.mxid, '@whatsapp_' || split_part(p.id, '@', 1) || ':${server_name}'
  FROM portal p
  JOIN whatsmeow_lid_map m ON m.pn || '@s.whatsapp.net' = p.id
  WHERE p.bridge_id = '' AND p.room_type = 'dm'
    AND p.id LIKE '%@s.whatsapp.net' AND p.mxid <> ''" >"$rooms_file"

total="$(wc -l <"$rooms_file")"
echo "PN DM portals with a Matrix room and a known LID: $total"
if [[ "$total" -eq 0 ]]; then : >"$blocked_file"; : >"$sql_file"; echo "nothing to do"; exit 0; fi

{
  echo "CREATE TEMP TABLE r(room text, ghost text);"
  echo "COPY r FROM STDIN;"
  cat "$rooms_file"
  echo '\.'
  cat <<SQL
SELECT r.room FROM r
LEFT JOIN current_state_events pls ON pls.room_id = r.room AND pls.type = 'm.room.power_levels' AND pls.state_key = ''
LEFT JOIN event_json ej ON ej.event_id = pls.event_id
WHERE NOT (
  EXISTS (SELECT 1 FROM local_current_membership m WHERE m.room_id = r.room AND m.user_id = r.ghost AND m.membership IN ('join','invite'))
  AND EXISTS (SELECT 1 FROM local_current_membership m WHERE m.room_id = r.room AND m.user_id = '${bot}' AND m.membership = 'join')
  AND COALESCE((ej.json::jsonb->'content'->'users'->>'${bot}')::int, (ej.json::jsonb->'content'->>'users_default')::int, 0)
      >= COALESCE((ej.json::jsonb->'content'->>'invite')::int, 0)
) ORDER BY 1;
SQL
} | k exec -i "$syn_primary" -c postgres -- psql -U postgres -d synapse -At -q -v ON_ERROR_STOP=1 >"$blocked_file"

blocked="$(wc -l <"$blocked_file")"
echo "migratable: $((total - blocked))   blocked (would crash-loop the bridge): $blocked"
echo "blocked room IDs: $blocked_file"

if [[ "$blocked" -gt 0 ]]; then
  list="$(sed "s/.*/'&'/" "$blocked_file" | paste -sd, -)"
  cat >"$sql_file" <<SQL
-- Detach $blocked PN DM portals the LID migration cannot re-ID (see $blocked_file).
-- Apply ONLY with the whatsapp Deployment at 0 replicas, after the CNPG backup.
BEGIN;
DELETE FROM disappearing_message WHERE bridge_id = '' AND mx_room IN ($list);
UPDATE portal SET mxid = NULL
 WHERE bridge_id = '' AND room_type = 'dm' AND id LIKE '%@s.whatsapp.net'
   AND mxid IN ($list);
COMMIT;
SQL
  echo "detach SQL: $sql_file"
else
  : >"$sql_file"
fi
