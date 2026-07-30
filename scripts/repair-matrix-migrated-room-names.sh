#!/usr/bin/env bash
set -euo pipefail
set +x

synapse_url="${SYNAPSE_URL:-http://127.0.0.1:8008}"
repair_user_id="${REPAIR_USER_ID:-}"
max_attempts="${MAX_ATTEMPTS:-8}"
request_delay_seconds="${REQUEST_DELAY_SECONDS:-1}"
curl_connect_timeout="${CURL_CONNECT_TIMEOUT:-10}"
curl_max_time="${CURL_MAX_TIME:-30}"

usage() {
  cat <<'EOF'
Usage:
  repair-matrix-migrated-room-names.sh inventory ROOM_NAME_FILE
  repair-matrix-migrated-room-names.sh repair ROOM_NAME_FILE

ROOM_NAME_FILE is tab-separated:

  room_id<TAB>desired room name

Required environment:
  ACCESS_TOKEN       Access token for a temporary Synapse server administrator
    or
  ACCESS_TOKEN_FILE  File containing that access token

Additionally required for repair:
  REPAIR_USER_ID     Matrix ID belonging to ACCESS_TOKEN

Optional environment:
  SYNAPSE_URL           Default: http://127.0.0.1:8008
  MAX_ATTEMPTS          Default: 8
  REQUEST_DELAY_SECONDS Default: 1

The repair command only names existing rooms. It never creates a room or a
bridge portal, and it never replaces a non-empty explicit m.room.name. It uses
Synapse's supported make_room_admin API, joins the temporary repair user,
writes m.room.name through the Matrix client API, verifies the state, and
leaves the room.
EOF
}

die() {
  echo "repair-matrix-migrated-room-names: $*" >&2
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

parse_room_name() {
  local record encoded_name

  record="$(
    python3 -c '
import base64
import json
import sys

response = json.load(sys.stdin)
event = next(
    (
        event
        for event in response.get("state", [])
        if event.get("type") == "m.room.name" and event.get("state_key", "") == ""
    ),
    None,
)
if event is None:
    state, name = "missing", ""
else:
    name = (event.get("content") or {}).get("name")
    if not isinstance(name, str):
        state, name = "invalid", ""
    elif name == "":
        state = "empty"
    else:
        state = "set"
encoded = base64.b64encode(name.encode()).decode()
print(f"{state}\t{encoded}", end="")
' <"$response_file"
  )" || return 1

  current_name_state="${record%%$'\t'*}"
  encoded_name="${record#*$'\t'}"
  current_name="$(
    python3 -c '
import base64
import sys

print(base64.b64decode(sys.argv[1]).decode(), end="")
' "$encoded_name"
  )"
}

read_room_name() {
  local room_id="$1"
  local encoded_room_id
  encoded_room_id="$(urlencode "$room_id")"
  read_error="-"
  read_detail="-"

  if ! retry_api_request GET \
    "${synapse_url%/}/_synapse/admin/v1/rooms/$encoded_room_id/state"; then
    read_error="state-request-failed"
    read_detail="$http_status"
    return 1
  fi
  if [[ ! "$http_status" =~ ^2 ]]; then
    read_error="state-error-$http_status"
    read_detail="$(json_error)"
    return 1
  fi
  if ! parse_room_name || [[ "$current_name_state" == "invalid" ]]; then
    current_name_state="invalid"
    current_name=""
    read_error="invalid-room-name-state"
    return 1
  fi
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

display_current_name() {
  case "$current_name_state" in
    missing) printf '<missing>' ;;
    empty) printf '<empty>' ;;
    *) tsv_value "$current_name" ;;
  esac
}

emit_result() {
  local room_id="$1"
  local desired_name="$2"
  local status="$3"
  local error="$4"

  printf '%s\t' "$room_id"
  tsv_value "$desired_name"
  printf '\t'
  display_current_name
  printf '\t%s\t%s\n' "$status" "$error"
}

inventory_room() {
  local room_id="$1"
  local desired_name="$2"

  current_name_state="missing"
  current_name=""
  if ! read_room_name "$room_id"; then
    emit_result "$room_id" "$desired_name" "$read_error" "$read_detail"
    return 1
  fi

  if [[ "$current_name_state" == "set" && "$current_name" == "$desired_name" ]]; then
    emit_result "$room_id" "$desired_name" "ready" "-"
  elif [[ "$current_name_state" == "set" ]]; then
    emit_result "$room_id" "$desired_name" "protected-existing-name" "-"
  else
    emit_result "$room_id" "$desired_name" "needs-repair" "-"
  fi
}

make_repair_user_admin() {
  local room_id="$1"
  local encoded_room_id payload error
  encoded_room_id="$(urlencode "$room_id")"
  payload="$(
    python3 -c '
import json
import sys

print(json.dumps({"user_id": sys.argv[1]}, separators=(",", ":")), end="")
' "$repair_user_id"
  )"

  if ! retry_api_request POST \
    "${synapse_url%/}/_synapse/admin/v1/rooms/$encoded_room_id/make_room_admin" \
    "$payload"; then
    repair_error="admin-request-failed"
    repair_detail="-"
    return 1
  fi
  if [[ "$http_status" =~ ^2 ]]; then
    return 0
  fi
  if [[ "$http_status" == "429" ]]; then
    repair_error="admin-retries-exhausted"
    repair_detail="-"
    return 1
  fi

  error="$(json_error)"
  if [[ "$http_status" == "400" && "$error" == *"No local admin user in room"* ]]; then
    repair_error="no-local-admin"
    repair_detail="-"
  else
    repair_error="admin-error-$http_status"
    repair_detail="$error"
  fi
  return 1
}

join_room() {
  local room_id="$1"
  local encoded_room_id
  encoded_room_id="$(urlencode "$room_id")"

  if ! retry_api_request POST \
    "${synapse_url%/}/_matrix/client/v3/join/$encoded_room_id" '{}'; then
    repair_error="join-request-failed"
    repair_detail="-"
    return 1
  fi
  if [[ "$http_status" =~ ^2 ]]; then
    return 0
  fi
  repair_error="$([[ "$http_status" == "429" ]] && echo join-retries-exhausted || echo join-error-"$http_status")"
  repair_detail="$([[ "$http_status" == "429" ]] && echo - || json_error)"
  return 1
}

write_room_name() {
  local room_id="$1"
  local desired_name="$2"
  local encoded_room_id payload
  encoded_room_id="$(urlencode "$room_id")"
  payload="$(
    python3 -c '
import json
import sys

print(json.dumps({"name": sys.argv[1]}, ensure_ascii=False, separators=(",", ":")), end="")
' "$desired_name"
  )"

  if ! retry_api_request PUT \
    "${synapse_url%/}/_matrix/client/v3/rooms/$encoded_room_id/state/m.room.name" \
    "$payload"; then
    repair_error="state-request-failed"
    repair_detail="-"
    return 1
  fi
  if [[ "$http_status" =~ ^2 ]]; then
    return 0
  fi
  repair_error="$([[ "$http_status" == "429" ]] && echo state-retries-exhausted || echo state-error-"$http_status")"
  repair_detail="$([[ "$http_status" == "429" ]] && echo - || json_error)"
  return 1
}

remove_repair_user_power() {
  local room_id="$1"
  local encoded_room_id record encoded_payload payload
  encoded_room_id="$(urlencode "$room_id")"

  if ! retry_api_request GET \
    "${synapse_url%/}/_synapse/admin/v1/rooms/$encoded_room_id/state"; then
    repair_error="power-state-request-failed"
    repair_detail="-"
    return 1
  fi
  if [[ ! "$http_status" =~ ^2 ]]; then
    repair_error="power-state-error-$http_status"
    repair_detail="$(json_error)"
    return 1
  fi

  if ! record="$(
    python3 -c '
import base64
import json
import sys

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
if event is None or not isinstance(event.get("content"), dict):
    raise SystemExit(1)

content = event["content"]
users = content.get("users")
if not isinstance(users, dict):
    users = {}
    content["users"] = users
removed = users.pop(sys.argv[1], None) is not None
payload = json.dumps(
    content,
    ensure_ascii=False,
    separators=(",", ":"),
).encode()
print(
    f"{1 if removed else 0}\t{base64.b64encode(payload).decode()}",
    end="",
)
' "$repair_user_id" <"$response_file"
  )"; then
    repair_error="invalid-power-level-state"
    repair_detail="-"
    return 1
  fi

  if [[ "${record%%$'\t'*}" != "1" ]]; then
    repair_error="repair-user-power-missing"
    repair_detail="-"
    return 1
  fi
  encoded_payload="${record#*$'\t'}"
  payload="$(
    python3 -c '
import base64
import sys

print(base64.b64decode(sys.argv[1]).decode(), end="")
' "$encoded_payload"
  )"

  if ! retry_api_request PUT \
    "${synapse_url%/}/_matrix/client/v3/rooms/$encoded_room_id/state/m.room.power_levels" \
    "$payload"; then
    repair_error="power-cleanup-request-failed"
    repair_detail="-"
    return 1
  fi
  if [[ "$http_status" =~ ^2 ]]; then
    return 0
  fi
  repair_error="$([[ "$http_status" == "429" ]] && echo power-cleanup-retries-exhausted || echo power-cleanup-error-"$http_status")"
  repair_detail="$([[ "$http_status" == "429" ]] && echo - || json_error)"
  return 1
}

leave_room() {
  local room_id="$1"
  local encoded_room_id
  encoded_room_id="$(urlencode "$room_id")"

  retry_api_request POST \
    "${synapse_url%/}/_matrix/client/v3/rooms/$encoded_room_id/leave" '{}' &&
    [[ "$http_status" =~ ^2 ]]
}

repair_room() {
  local room_id="$1"
  local desired_name="$2"
  local repair_error="unknown-error"
  local repair_detail="-"

  current_name_state="missing"
  current_name=""
  if ! read_room_name "$room_id"; then
    emit_result "$room_id" "$desired_name" "$read_error" "$read_detail"
    return 1
  fi
  if [[ "$current_name_state" == "set" && "$current_name" == "$desired_name" ]]; then
    emit_result "$room_id" "$desired_name" "already-ready" "-"
    return 0
  fi
  if [[ "$current_name_state" == "set" ]]; then
    emit_result "$room_id" "$desired_name" "protected-existing-name" "-"
    return 0
  fi

  if ! make_repair_user_admin "$room_id"; then
    emit_result "$room_id" "$desired_name" "$repair_error" "$repair_detail"
    return 1
  fi
  if ! join_room "$room_id"; then
    emit_result "$room_id" "$desired_name" "$repair_error" "$repair_detail"
    return 1
  fi
  if ! write_room_name "$room_id" "$desired_name"; then
    remove_repair_user_power "$room_id" || true
    leave_room "$room_id" || true
    emit_result "$room_id" "$desired_name" "$repair_error" "$repair_detail"
    return 1
  fi

  sleep "$request_delay_seconds"
  if ! read_room_name "$room_id"; then
    remove_repair_user_power "$room_id" || true
    leave_room "$room_id" || true
    emit_result "$room_id" "$desired_name" "$read_error" "$read_detail"
    return 1
  fi
  if [[ "$current_name_state" != "set" || "$current_name" != "$desired_name" ]]; then
    remove_repair_user_power "$room_id" || true
    leave_room "$room_id" || true
    emit_result "$room_id" "$desired_name" "verification-failed" "-"
    return 1
  fi
  if ! remove_repair_user_power "$room_id"; then
    leave_room "$room_id" || true
    emit_result "$room_id" "$desired_name" "$repair_error" "$repair_detail"
    return 1
  fi
  if ! leave_room "$room_id"; then
    emit_result "$room_id" "$desired_name" "repaired-leave-failed" "$http_status"
    return 1
  fi

  emit_result "$room_id" "$desired_name" "repaired" "-"
}

process_rooms() {
  local command="$1"
  local room_file="$2"
  local line room_id desired_name
  local total=0 succeeded=0 failed=0

  printf 'room_id\tdesired_name\tcurrent_name\tstatus\terror\n'
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" && "$line" != \#* && "$line" != room_id$'\t'* ]] || continue
    if [[ "$line" != *$'\t'* ]]; then
      echo "Skipping row without a tab-separated desired name." >&2
      ((failed += 1))
      continue
    fi
    room_id="${line%%$'\t'*}"
    desired_name="${line#*$'\t'}"
    if [[ "$desired_name" == *$'\t'* ]]; then
      echo "Skipping desired name containing a tab." >&2
      ((failed += 1))
      continue
    fi
    if [[ "$room_id" != \!?* || "$room_id" =~ [[:space:]] || -z "$desired_name" ]]; then
      echo "Skipping invalid room ID or empty desired name." >&2
      ((failed += 1))
      continue
    fi

    ((total += 1))
    if "${command}_room" "$room_id" "$desired_name"; then
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
  [[ -n "$room_file" && -r "$room_file" ]] ||
    die "ROOM_NAME_FILE is required and must be readable"
  [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] ||
    die "MAX_ATTEMPTS must be a positive integer"
  if [[ "$command" == "repair" ]]; then
    [[ "$repair_user_id" == @*:* ]] || die "REPAIR_USER_ID must be a Matrix user ID"
  fi

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
