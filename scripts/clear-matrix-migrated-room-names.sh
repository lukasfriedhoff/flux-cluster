#!/usr/bin/env bash
set -euo pipefail
set +x

synapse_url="${SYNAPSE_URL:-http://127.0.0.1:8008}"
max_attempts="${MAX_ATTEMPTS:-8}"
request_delay_seconds="${REQUEST_DELAY_SECONDS:-1}"
curl_connect_timeout="${CURL_CONNECT_TIMEOUT:-10}"
curl_max_time="${CURL_MAX_TIME:-30}"

usage() {
  cat <<'EOF'
Usage:
  clear-matrix-migrated-room-names.sh inventory ROOM_STATE_FILE
  clear-matrix-migrated-room-names.sh apply ROOM_STATE_FILE

ROOM_STATE_FILE is tab-separated:

  room_id<TAB>expected event ID<TAB>expected sender<TAB>expected non-empty name

Required environment:
  ACCESS_TOKEN       Access token for a Synapse server administrator
    or
  ACCESS_TOKEN_FILE  File containing that access token

Optional environment:
  SYNAPSE_URL           Default: http://127.0.0.1:8008
  MAX_ATTEMPTS          Default: 8
  REQUEST_DELAY_SECONDS Default: 1

This is a rollback-only tool for explicit m.room.name events written during a
migration repair. It clears a name only when the current event ID, sender, and
non-empty value exactly match the supplied inventory.

The tool never creates or joins rooms, invites users, changes power levels, or
writes a replacement name. The token user must already be joined and allowed
to send m.room.name state events before apply can clear a matching name.
EOF
}

die() {
  echo "clear-matrix-migrated-room-names: $*" >&2
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "missing required binary: $1"
}

load_access_token() {
  if [[ -n "${ACCESS_TOKEN:-}" ]]; then
    access_token="$ACCESS_TOKEN"
  elif [[ -n "${ACCESS_TOKEN_FILE:-}" ]]; then
    [[ -r "$ACCESS_TOKEN_FILE" ]] || die "cannot read ACCESS_TOKEN_FILE"
    access_token="$(<"$ACCESS_TOKEN_FILE")"
  else
    die "set ACCESS_TOKEN or ACCESS_TOKEN_FILE"
  fi

  access_token="${access_token//$'\r'/}"
  access_token="${access_token//$'\n'/}"
  [[ -n "$access_token" ]] || die "access token is empty"
}

urlencode() {
  local input="$1"
  local output=""
  local char code
  local index

  LC_ALL=C
  for ((index = 0; index < ${#input}; index++)); do
    char="${input:index:1}"
    case "$char" in
      [a-zA-Z0-9.~_-])
        output+="$char"
        ;;
      *)
        printf -v code '%%%02X' "'$char"
        output+="$code"
        ;;
    esac
  done
  printf '%s' "$output"
}

json_error() {
  python3 -c '
import json
import sys

try:
    response = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError):
    print("invalid JSON response", end="")
else:
    print(response.get("error") or response.get("errcode") or "unknown API error", end="")
' <"$response_file"
}

retry_after_ms() {
  python3 -c '
import json
import sys

try:
    response = json.load(sys.stdin)
    delay = int(response.get("retry_after_ms") or 1000)
except (json.JSONDecodeError, TypeError, ValueError, UnicodeDecodeError):
    delay = 1000
print(delay, end="")
' <"$response_file"
}

api_request() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local curl_args=(
    --silent
    --show-error
    --connect-timeout "$curl_connect_timeout"
    --max-time "$curl_max_time"
    --request "$method"
    --header "Authorization: Bearer $access_token"
    --output "$response_file"
    --write-out '%{http_code}'
  )

  if [[ -n "$data" ]]; then
    curl_args+=(--header 'Content-Type: application/json' --data "$data")
  fi

  if ! http_status="$(curl "${curl_args[@]}" "$url")"; then
    http_status="000"
    return 1
  fi
}

retry_api_request() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local attempt delay_ms delay_seconds

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    api_request "$method" "$url" "$data" || return 1
    [[ "$http_status" == "429" ]] || return 0
    delay_ms="$(retry_after_ms)"
    delay_seconds="$(((delay_ms + 999) / 1000))"
    ((delay_seconds > 0)) || delay_seconds=1
    sleep "$delay_seconds"
  done
  return 0
}

decode_base64() {
  if [[ "$1" == "-" ]]; then
    return
  fi
  python3 -c '
import base64
import sys

print(base64.b64decode(sys.argv[1]).decode(), end="")
' "$1"
}

parse_room_state() {
  local record
  local encoded_event_id encoded_sender encoded_name

  record="$(
    python3 -c '
import base64
import json
import sys

user_id = sys.argv[1]
response = json.load(sys.stdin)
events = response.get("state", [])
name_event = next(
    (
        event
        for event in events
        if event.get("type") == "m.room.name" and event.get("state_key", "") == ""
    ),
    None,
)
member_event = next(
    (
        event
        for event in events
        if event.get("type") == "m.room.member" and event.get("state_key") == user_id
    ),
    None,
)

def encode(value):
    return base64.b64encode(value.encode()).decode() or "-"

if name_event is None:
    name_state = "missing"
    event_id = sender = name = ""
else:
    event_id = name_event.get("event_id")
    sender = name_event.get("sender")
    name = (name_event.get("content") or {}).get("name")
    if not isinstance(event_id, str) or not isinstance(sender, str) or not isinstance(name, str):
        name_state = "invalid"
        event_id = event_id if isinstance(event_id, str) else ""
        sender = sender if isinstance(sender, str) else ""
        name = name if isinstance(name, str) else ""
    elif name == "":
        name_state = "empty"
    else:
        name_state = "set"

membership = ""
if member_event is not None:
    value = (member_event.get("content") or {}).get("membership")
    if isinstance(value, str):
        membership = value

print(
    "\t".join(
        (
            name_state,
            encode(event_id),
            encode(sender),
            encode(name),
            membership or "missing",
        )
    ),
    end="",
)
' "$token_user_id" <"$response_file"
  )" || return 1

  IFS=$'\t' read -r \
    current_name_state \
    encoded_event_id \
    encoded_sender \
    encoded_name \
    current_membership <<<"$record"

  current_event_id="$(decode_base64 "$encoded_event_id")"
  current_sender="$(decode_base64 "$encoded_sender")"
  current_name="$(decode_base64 "$encoded_name")"
}

read_room_state() {
  local room_id="$1"
  local encoded_room_id
  encoded_room_id="$(urlencode "$room_id")"
  read_error="-"

  if ! retry_api_request GET \
    "${synapse_url%/}/_synapse/admin/v1/rooms/$encoded_room_id/state"; then
    read_error="state-request-failed-$http_status"
    return 1
  fi
  if [[ ! "$http_status" =~ ^2 ]]; then
    read_error="state-error-$http_status-$(json_error)"
    return 1
  fi
  if ! parse_room_state || [[ "$current_name_state" == "invalid" ]]; then
    current_name_state="invalid"
    current_event_id=""
    current_sender=""
    current_name=""
    current_membership="missing"
    read_error="invalid-room-state"
    return 1
  fi
}

read_token_user() {
  if ! retry_api_request GET \
    "${synapse_url%/}/_matrix/client/v3/account/whoami"; then
    die "whoami request failed"
  fi
  [[ "$http_status" =~ ^2 ]] || die "whoami failed: HTTP $http_status: $(json_error)"
  token_user_id="$(
    python3 -c '
import json
import sys

user_id = json.load(sys.stdin).get("user_id")
if not isinstance(user_id, str) or not user_id:
    raise SystemExit(1)
print(user_id, end="")
' <"$response_file"
  )" || die "whoami returned no user_id"
}

tsv_value() {
  python3 -c '
import sys

print(
    sys.argv[1]
    .replace("\\", "\\\\")
    .replace("\t", "\\t")
    .replace("\r", "\\r")
    .replace("\n", "\\n"),
    end="",
)
' "$1"
}

display_value() {
  local value="$1"
  if [[ -n "$value" ]]; then
    tsv_value "$value"
  else
    printf '<none>'
  fi
}

emit_result() {
  local room_id="$1"
  local expected_name="$2"
  local status="$3"
  local error="$4"

  printf '%s\t' "$room_id"
  display_value "$expected_name"
  printf '\t'
  display_value "$current_event_id"
  printf '\t'
  display_value "$current_sender"
  printf '\t'
  display_value "$current_name"
  printf '\t%s\t%s\t%s\n' "$current_membership" "$status" "$error"
}

clear_room_name() {
  local room_id="$1"
  local encoded_room_id
  encoded_room_id="$(urlencode "$room_id")"

  if ! retry_api_request PUT \
    "${synapse_url%/}/_matrix/client/v3/rooms/$encoded_room_id/state/m.room.name" \
    '{"name":""}'; then
    clear_error="clear-request-failed-$http_status"
    return 1
  fi
  if [[ ! "$http_status" =~ ^2 ]]; then
    clear_error="clear-error-$http_status-$(json_error)"
    return 1
  fi

  sleep "$request_delay_seconds"
  if ! read_room_state "$room_id"; then
    clear_error="verification-$read_error"
    return 1
  fi
  if [[ "$current_name_state" != "empty" && "$current_name_state" != "missing" ]]; then
    clear_error="verification-name-still-set"
    return 1
  fi
}

[[ $# -eq 2 ]] || {
  usage >&2
  exit 2
}

mode="$1"
room_state_file="$2"
[[ "$mode" == "inventory" || "$mode" == "apply" ]] || die "mode must be inventory or apply"
[[ -r "$room_state_file" ]] || die "cannot read room state file: $room_state_file"
[[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || die "MAX_ATTEMPTS must be a positive integer"
[[ "$request_delay_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
  die "REQUEST_DELAY_SECONDS must be a non-negative number"

require_bin curl
require_bin python3
load_access_token

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT
read_token_user

declare -A seen_rooms=()
had_error=0

printf 'room_id\texpected_name\tcurrent_event_id\tcurrent_sender\tcurrent_name\tmembership\tstatus\terror\n'
while IFS=$'\t' read -r \
  room_id \
  expected_event_id \
  expected_sender \
  expected_name \
  extra; do
  [[ -n "$room_id" ]] || continue
  [[ "$room_id" == \#* ]] && continue
  [[ -z "${extra:-}" ]] || die "too many fields for room $room_id"
  [[ "$room_id" == '!'* ]] || die "invalid room ID: $room_id"
  [[ -n "$expected_event_id" ]] || die "missing expected event ID for $room_id"
  [[ -n "$expected_sender" ]] || die "missing expected sender for $room_id"
  [[ -n "$expected_name" ]] || die "expected name must be non-empty for $room_id"
  [[ -z "${seen_rooms[$room_id]:-}" ]] || die "duplicate room ID: $room_id"
  seen_rooms["$room_id"]=1

  current_name_state="invalid"
  current_event_id=""
  current_sender=""
  current_name=""
  current_membership="missing"

  if ! read_room_state "$room_id"; then
    emit_result "$room_id" "$expected_name" "error" "$read_error"
    had_error=1
    continue
  fi

  if [[ "$current_name_state" == "empty" || "$current_name_state" == "missing" ]]; then
    emit_result "$room_id" "$expected_name" "already-clear" "-"
    continue
  fi

  if [[ "$current_event_id" != "$expected_event_id" ||
    "$current_sender" != "$expected_sender" ||
    "$current_name" != "$expected_name" ]]; then
    emit_result "$room_id" "$expected_name" "protected-state-drift" "-"
    continue
  fi

  if [[ "$mode" == "inventory" ]]; then
    emit_result "$room_id" "$expected_name" "needs-clear" "-"
    continue
  fi

  if [[ "$current_membership" != "join" ]]; then
    emit_result "$room_id" "$expected_name" "blocked-not-joined" "-"
    had_error=1
    continue
  fi

  clear_error="-"
  if clear_room_name "$room_id"; then
    emit_result "$room_id" "$expected_name" "cleared" "-"
  else
    emit_result "$room_id" "$expected_name" "error" "$clear_error"
    had_error=1
  fi
done <"$room_state_file"

exit "$had_error"
