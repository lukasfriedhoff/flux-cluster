#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repair_script="$repo_root/scripts/repair-matrix-migrated-room-names.sh"

fail() {
  echo "verify-matrix-migrated-room-name-repair: $*" >&2
  exit 1
}

command -v python3 >/dev/null || fail "python3 is required"

umask 077
tmpdir="$(mktemp -d)"
server_pid=""
trap '[[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true; rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/server.py" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

REPAIR_USER = "@repair:new.example"
ROOMS = {
    "!repairable:old.example": {
        "members": {"@admin:new.example"},
        "users": {"@admin:new.example": 100},
        "name": None,
    },
    "!empty:old.example": {
        "members": {"@admin:new.example"},
        "users": {"@admin:new.example": 100},
        "name": "",
    },
    "!modern_room_id_without_server": {
        "members": {"@admin:new.example"},
        "users": {"@admin:new.example": 100},
        "name": None,
    },
    "!protected:old.example": {
        "members": {"@admin:new.example"},
        "users": {"@admin:new.example": 100},
        "name": "Existing explicit name",
    },
    "!ready:old.example": {
        "members": {"@admin:new.example"},
        "users": {"@admin:new.example": 100},
        "name": "Sophie",
    },
    "!blocked:old.example": {
        "members": {"@admin:old.example"},
        "users": {"@admin:old.example": 100},
        "name": None,
    },
}
RATE_LIMITED = set()
LEAVE_RATE_LIMITED = set()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def respond(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def room_from_path(self, prefix, suffix):
        return unquote(self.path[len(prefix) : -len(suffix)])

    def do_GET(self):
        prefix = "/_synapse/admin/v1/rooms/"
        suffix = "/state"
        if not self.path.startswith(prefix) or not self.path.endswith(suffix):
            self.respond(404, {"errcode": "M_NOT_FOUND"})
            return
        room_id = self.room_from_path(prefix, suffix)
        room = ROOMS.get(room_id)
        if room is None:
            self.respond(404, {"errcode": "M_NOT_FOUND", "error": "Unknown room"})
            return
        state = [
            {
                "type": "m.room.power_levels",
                "state_key": "",
                "content": {"users_default": 0, "users": room["users"]},
            }
        ]
        if room["name"] is not None:
            state.append(
                {
                    "type": "m.room.name",
                    "state_key": "",
                    "content": {"name": room["name"]},
                }
            )
        self.respond(200, {"state": state})

    def do_PUT(self):
        prefix = "/_matrix/client/v3/rooms/"
        name_suffix = "/state/m.room.name"
        power_suffix = "/state/m.room.power_levels"
        if not self.path.startswith(prefix):
            self.respond(404, {"errcode": "M_NOT_FOUND"})
            return
        if self.path.endswith(name_suffix):
            suffix = name_suffix
        elif self.path.endswith(power_suffix):
            suffix = power_suffix
        else:
            self.respond(404, {"errcode": "M_NOT_FOUND"})
            return
        room_id = self.room_from_path(prefix, suffix)
        room = ROOMS.get(room_id)
        if room is None:
            self.respond(404, {"errcode": "M_NOT_FOUND"})
            return
        if suffix == name_suffix and room["name"]:
            self.respond(409, {"errcode": "M_CONFLICT", "error": "Name already exists"})
            return
        if REPAIR_USER not in room["members"]:
            self.respond(403, {"errcode": "M_FORBIDDEN", "error": "User not in room"})
            return
        if room["users"].get(REPAIR_USER) != 100:
            self.respond(403, {"errcode": "M_FORBIDDEN", "error": "Insufficient power"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length))
        if suffix == power_suffix:
            room["users"] = payload.get("users", {})
            self.respond(200, {"event_id": "$power"})
            return
        room["name"] = payload["name"]
        self.respond(200, {"event_id": "$name"})

    def do_POST(self):
        admin_prefix = "/_synapse/admin/v1/rooms/"
        admin_suffix = "/make_room_admin"
        join_prefix = "/_matrix/client/v3/join/"
        leave_prefix = "/_matrix/client/v3/rooms/"
        leave_suffix = "/leave"

        if self.path.startswith(admin_prefix) and self.path.endswith(admin_suffix):
            room_id = self.room_from_path(admin_prefix, admin_suffix)
            room = ROOMS.get(room_id)
            if room is None:
                self.respond(404, {"errcode": "M_NOT_FOUND"})
                return
            if room_id == "!repairable:old.example" and room_id not in RATE_LIMITED:
                RATE_LIMITED.add(room_id)
                self.respond(429, {"errcode": "M_LIMIT_EXCEEDED", "retry_after_ms": 1})
                return
            if room_id == "!blocked:old.example":
                self.respond(400, {"error": "No local admin user in room"})
                return
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length))
            room["users"][payload["user_id"]] = 100
            self.respond(200, {})
            return

        if self.path.startswith(join_prefix):
            room_id = unquote(self.path[len(join_prefix) :])
            room = ROOMS.get(room_id)
            if room is None:
                self.respond(404, {"errcode": "M_NOT_FOUND"})
                return
            room["members"].add(REPAIR_USER)
            self.respond(200, {"room_id": room_id})
            return

        if self.path.startswith(leave_prefix) and self.path.endswith(leave_suffix):
            room_id = self.room_from_path(leave_prefix, leave_suffix)
            room = ROOMS.get(room_id)
            if room is None:
                self.respond(404, {"errcode": "M_NOT_FOUND"})
                return
            if room_id == "!repairable:old.example" and room_id not in LEAVE_RATE_LIMITED:
                LEAVE_RATE_LIMITED.add(room_id)
                self.respond(429, {"errcode": "M_LIMIT_EXCEEDED", "retry_after_ms": 1})
                return
            room["members"].discard(REPAIR_USER)
            self.respond(200, {})
            return

        self.respond(404, {"errcode": "M_NOT_FOUND"})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY

python3 "$tmpdir/server.py" >"$tmpdir/port" &
server_pid="$!"
for _ in {1..50}; do
  [[ -s "$tmpdir/port" ]] && break
  sleep 0.1
done
[[ -s "$tmpdir/port" ]] || fail "mock server did not start"
port="$(cat "$tmpdir/port")"

cat >"$tmpdir/rooms" <<'EOF'
!repairable:old.example	Marvin
!empty:old.example	Partner with Ümlaut
!modern_room_id_without_server	Ibon
!protected:old.example	Wrong replacement
!ready:old.example	Sophie
EOF

common_env=(
  "SYNAPSE_URL=http://127.0.0.1:$port"
  "ACCESS_TOKEN=test-token"
  "REPAIR_USER_ID=@repair:new.example"
  "REQUEST_DELAY_SECONDS=0"
)

env "${common_env[@]}" "$repair_script" inventory "$tmpdir/rooms" >"$tmpdir/inventory"
grep -F $'!repairable:old.example\tMarvin\t<missing>\tneeds-repair' "$tmpdir/inventory" >/dev/null ||
  fail "missing room name was not detected"
grep -F $'!empty:old.example\tPartner with Ümlaut\t<empty>\tneeds-repair' "$tmpdir/inventory" >/dev/null ||
  fail "empty room name was not detected"
grep -F $'!modern_room_id_without_server\tIbon\t<missing>\tneeds-repair' "$tmpdir/inventory" >/dev/null ||
  fail "modern room ID without a server-name suffix was not accepted"
grep -F $'!protected:old.example\tWrong replacement\tExisting explicit name\tprotected-existing-name' "$tmpdir/inventory" >/dev/null ||
  fail "existing explicit room name was not protected"
grep -F $'!ready:old.example\tSophie\tSophie\tready' "$tmpdir/inventory" >/dev/null ||
  fail "matching explicit room name was not ready"

env "${common_env[@]}" "$repair_script" repair "$tmpdir/rooms" >"$tmpdir/repaired"
grep -F $'!repairable:old.example\tMarvin\tMarvin\trepaired' "$tmpdir/repaired" >/dev/null ||
  fail "missing room name was not repaired"
grep -F $'!empty:old.example\tPartner with Ümlaut\tPartner with Ümlaut\trepaired' "$tmpdir/repaired" >/dev/null ||
  fail "empty room name was not repaired"
grep -F $'!modern_room_id_without_server\tIbon\tIbon\trepaired' "$tmpdir/repaired" >/dev/null ||
  fail "modern room ID without a server-name suffix was not repaired"
grep -F $'!protected:old.example\tWrong replacement\tExisting explicit name\tprotected-existing-name' "$tmpdir/repaired" >/dev/null ||
  fail "existing explicit room name was overwritten"
grep -F $'!ready:old.example\tSophie\tSophie\talready-ready' "$tmpdir/repaired" >/dev/null ||
  fail "matching room name was not left unchanged"

for room_id in \
  '%21repairable%3Aold.example' \
  '%21empty%3Aold.example' \
  '%21modern_room_id_without_server'; do
  curl --fail --silent \
    "http://127.0.0.1:$port/_synapse/admin/v1/rooms/$room_id/state" |
    python3 -c '
import json
import sys

state = json.load(sys.stdin)["state"]
power = next(event for event in state if event["type"] == "m.room.power_levels")
if "@repair:new.example" in power["content"].get("users", {}):
    raise SystemExit(1)
' || fail "repair user remained in room power levels"
done

env "${common_env[@]}" "$repair_script" inventory "$tmpdir/rooms" >"$tmpdir/recheck"
grep -F $'!repairable:old.example\tMarvin\tMarvin\tready' "$tmpdir/recheck" >/dev/null ||
  fail "repaired room name did not persist"
grep -F $'!modern_room_id_without_server\tIbon\tIbon\tready' "$tmpdir/recheck" >/dev/null ||
  fail "modern room ID repair did not persist"
grep -F $'!protected:old.example\tWrong replacement\tExisting explicit name\tprotected-existing-name' "$tmpdir/recheck" >/dev/null ||
  fail "protected room name changed"

printf '%s\n' $'!blocked:old.example\tBlocked partner' >"$tmpdir/blocked"
if env "${common_env[@]}" "$repair_script" repair "$tmpdir/blocked" >"$tmpdir/blocked-output"; then
  fail "room without a current local admin unexpectedly succeeded"
fi
grep -F $'!blocked:old.example\tBlocked partner\t<missing>\tno-local-admin' "$tmpdir/blocked-output" >/dev/null ||
  fail "room without a local admin was not classified"

echo "Matrix migrated-room name repair checks passed."
