#!/usr/bin/env bash
set -euo pipefail
set +x

synapse_url="${SYNAPSE_URL:-http://127.0.0.1:8008}"
target_user_id="${TARGET_USER_ID:-}"
required_power="${REQUIRED_POWER:-100}"
max_attempts="${MAX_ATTEMPTS:-8}"
request_delay_seconds="${REQUEST_DELAY_SECONDS:-1}"
curl_connect_timeout="${CURL_CONNECT_TIMEOUT:-10}"
curl_max_time="${CURL_MAX_TIME:-30}"

usage() {
  cat <<'EOF'
Usage:
  repair-matrix-migrated-room-admins.sh inventory ROOM_FILE
  repair-matrix-migrated-room-admins.sh repair ROOM_FILE

ROOM_FILE contains one Matrix room ID per line. Tab-separated inventory output
is also accepted; only the first column is used.

Required environment:
  TARGET_USER_ID     Matrix user to grant room administrator power
  ACCESS_TOKEN       Synapse server-admin access token
    or
  ACCESS_TOKEN_FILE  File containing the Synapse server-admin access token

Optional environment:
  SYNAPSE_URL             Default: http://127.0.0.1:8008
  REQUIRED_POWER          Default: 100
  MAX_ATTEMPTS            Default: 8
  REQUEST_DELAY_SECONDS   Default: 1

The repair command only calls Synapse's supported make_room_admin API. It does
not edit Synapse event or state tables. Synapse will refuse rooms without a
joined current-server user who can authorize the power-level event.
EOF
}

die() {
  echo "repair-matrix-migrated-room-admins: $*" >&2
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

target_power() {
  python3 -c '
import json
import sys

target_user_id = sys.argv[1]
response = json.load(sys.stdin)
event = next(
    (
        event
        for event in response.get("state", [])
        if event.get("type") == "m.room.power_levels"
        and event.get("state_key", "") == ""
    ),
    None,
)
if event is None:
    raise SystemExit("power-level event missing")
content = event.get("content") or {}
users = content.get("users") or {}
print(users.get(target_user_id, content.get("users_default", 0)), end="")
' "$target_user_id" <"$response_file"
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

read_target_power() {
  local room_id="$1"
  local encoded_room_id
  encoded_room_id="$(urlencode "$room_id")"

  if ! api_request GET \
    "${synapse_url%/}/_synapse/admin/v1/rooms/$encoded_room_id/state"; then
    printf '%s\t-\tstate-request-failed\t%s\n' "$room_id" "$http_status"
    return 1
  fi
  if [[ ! "$http_status" =~ ^2 ]]; then
    printf '%s\t-\tstate-error-%s\t%s\n' \
      "$room_id" "$http_status" "$(json_error)"
    return 1
  fi
  if ! power="$(target_power)"; then
    printf '%s\t-\tinvalid-power-levels\t-\n' "$room_id"
    return 1
  fi
}

inventory_room() {
  local room_id="$1"

  if ! read_target_power "$room_id"; then
    return 1
  fi
  if ((power >= required_power)); then
    printf '%s\t%s\tadmin\t-\n' "$room_id" "$power"
  else
    printf '%s\t%s\tneeds-repair\t-\n' "$room_id" "$power"
  fi
}

repair_room() {
  local room_id="$1"
  local attempt delay_ms delay_seconds payload error
  local encoded_room_id

  if ! read_target_power "$room_id"; then
    return 1
  fi
  if ((power >= required_power)); then
    printf '%s\t%s\talready-admin\t-\n' "$room_id" "$power"
    return 0
  fi

  encoded_room_id="$(urlencode "$room_id")"
  payload="$(
    python3 -c '
import json
import sys

print(json.dumps({"user_id": sys.argv[1]}, separators=(",", ":")), end="")
' "$target_user_id"
  )"

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! api_request POST \
      "${synapse_url%/}/_synapse/admin/v1/rooms/$encoded_room_id/make_room_admin" \
      "$payload"; then
      printf '%s\t%s\trepair-request-failed\t%s\n' \
        "$room_id" "$power" "$http_status"
      return 1
    fi
    if [[ "$http_status" =~ ^2 ]]; then
      break
    fi
    if [[ "$http_status" == "429" ]]; then
      delay_ms="$(retry_after_ms)"
      delay_seconds="$(((delay_ms + 999) / 1000))"
      ((delay_seconds > 0)) || delay_seconds=1
      sleep "$delay_seconds"
      continue
    fi

    error="$(json_error)"
    if [[ "$http_status" == "400" && "$error" == *"No local admin user in room"* ]]; then
      printf '%s\t%s\tno-local-admin\t%s\n' "$room_id" "$power" "$error"
    else
      printf '%s\t%s\trepair-error-%s\t%s\n' \
        "$room_id" "$power" "$http_status" "$error"
    fi
    return 1
  done

  if [[ ! "$http_status" =~ ^2 ]]; then
    printf '%s\t%s\trepair-retries-exhausted\t%s\n' \
      "$room_id" "$power" "$http_status"
    return 1
  fi

  sleep "$request_delay_seconds"
  if ! read_target_power "$room_id"; then
    return 1
  fi
  if ((power < required_power)); then
    printf '%s\t%s\tverification-failed\t-\n' "$room_id" "$power"
    return 1
  fi

  printf '%s\t%s\trepaired\t-\n' "$room_id" "$power"
}

process_rooms() {
  local command="$1"
  local room_file="$2"
  local line room_id
  local total=0 succeeded=0 failed=0

  printf 'room_id\ttarget_power\tstatus\terror\n'
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" && "$line" != \#* && "$line" != room_id$'\t'* ]] || continue
    room_id="${line%%$'\t'*}"
    [[ "$room_id" == '!'*:* ]] || {
      echo "Skipping invalid room ID." >&2
      ((failed += 1))
      continue
    }

    ((total += 1))
    if "${command}_room" "$room_id"; then
      ((succeeded += 1))
    else
      ((failed += 1))
    fi
    if [[ "$command" == "repair" ]]; then
      sleep "$request_delay_seconds"
    fi
  done <"$room_file"

  echo "Processed $total rooms: $succeeded succeeded, $failed require attention." >&2
  ((failed == 0))
}

main() {
  local command="${1:-}"
  local room_file="${2:-}"

  [[ "$command" == "inventory" || "$command" == "repair" ]] || {
    usage >&2
    exit 2
  }
  [[ -n "$room_file" && -r "$room_file" ]] || die "ROOM_FILE is required and must be readable"
  [[ "$target_user_id" == @*:* ]] || die "TARGET_USER_ID must be a Matrix user ID"
  [[ "$required_power" =~ ^[0-9]+$ ]] || die "REQUIRED_POWER must be an integer"
  [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || die "MAX_ATTEMPTS must be a positive integer"

  require_bin curl
  require_bin python3
  load_access_token

  umask 077
  tmpdir="$(mktemp -d)"
  response_file="$tmpdir/response.json"
  trap 'rm -rf "$tmpdir"' EXIT

  process_rooms "$command" "$room_file"
}

main "$@"
