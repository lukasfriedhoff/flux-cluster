#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repair_script="$repo_root/scripts/repair-matrix-migrated-history-visibility.sh"

fail() {
  echo "verify-matrix-migrated-history-visibility: $*" >&2
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
        "visibility": "joined",
    },
    "!blocked:old.example": {
        "members": {"@admin:old.example"},
        "users": {"@admin:old.example": 100},
        "visibility": "joined",
    },
    "!ready:old.example": {
        "members": {"@admin:new.example"},
        "users": {"@admin:new.example": 100},
        "visibility": "shared",
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
        self.respond(
            200,
            {
                "state": [
                    {
                        "type": "m.room.power_levels",
                        "state_key": "",
                        "content": {"users_default": 0, "users": room["users"]},
                    },
                    {
                        "type": "m.room.history_visibility",
                        "state_key": "",
                        "content": {"history_visibility": room["visibility"]},
                    },
                ]
            },
        )

    def do_PUT(self):
        prefix = "/_matrix/client/v3/rooms/"
        suffix = "/state/m.room.history_visibility"
        if not self.path.startswith(prefix) or not self.path.endswith(suffix):
            self.respond(404, {"errcode": "M_NOT_FOUND"})
            return
        room_id = self.room_from_path(prefix, suffix)
        room = ROOMS.get(room_id)
        if room is None:
            self.respond(404, {"errcode": "M_NOT_FOUND"})
            return
        if REPAIR_USER not in room["members"]:
            self.respond(403, {"errcode": "M_FORBIDDEN", "error": "User not in room"})
            return
        if room["users"].get(REPAIR_USER) != 100:
            self.respond(403, {"errcode": "M_FORBIDDEN", "error": "Insufficient power"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length))
        room["visibility"] = payload["history_visibility"]
        self.respond(200, {"event_id": "$history"})

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
            room["users"].pop(REPAIR_USER, None)
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
!repairable:old.example
!blocked:old.example
!ready:old.example
EOF

common_env=(
  "SYNAPSE_URL=http://127.0.0.1:$port"
  "ACCESS_TOKEN=test-token"
  "REPAIR_USER_ID=@repair:new.example"
  "REQUEST_DELAY_SECONDS=0"
)

env "${common_env[@]}" "$repair_script" inventory "$tmpdir/rooms" >"$tmpdir/inventory"
grep -F $'!repairable:old.example\tjoined\tneeds-repair' "$tmpdir/inventory" >/dev/null ||
  fail "joined history was not detected"
grep -F $'!ready:old.example\tshared\tready' "$tmpdir/inventory" >/dev/null ||
  fail "shared history was not detected"

printf '%s\n' '!repairable:old.example' >"$tmpdir/repairable"
env "${common_env[@]}" "$repair_script" repair "$tmpdir/repairable" >"$tmpdir/repaired"
grep -F $'!repairable:old.example\tshared\trepaired' "$tmpdir/repaired" >/dev/null ||
  fail "history visibility was not repaired and verified"

env "${common_env[@]}" "$repair_script" inventory "$tmpdir/repairable" >"$tmpdir/recheck"
grep -F $'!repairable:old.example\tshared\tready' "$tmpdir/recheck" >/dev/null ||
  fail "repaired history visibility did not persist"

printf '%s\n' '!blocked:old.example' >"$tmpdir/blocked"
if env "${common_env[@]}" "$repair_script" repair "$tmpdir/blocked" >"$tmpdir/blocked-output"; then
  fail "room without a current local admin unexpectedly succeeded"
fi
grep -F $'!blocked:old.example\tjoined\tno-local-admin' "$tmpdir/blocked-output" >/dev/null ||
  fail "room without a local admin was not classified"

if grep -F 'No local admin user in room' "$tmpdir/blocked-output" >/dev/null; then
  fail "server error details leaked into the status field"
fi

echo "Matrix migrated-history visibility checks passed."
