#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repair_script="$repo_root/scripts/repair-matrix-migrated-room-admins.sh"

fail() {
  echo "verify-matrix-migrated-room-admin-repair: $*" >&2
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

TARGET = "@target:new.example"
ROOMS = {
    "!repairable:old.example": {"@admin:new.example": 100},
    "!blocked:old.example": {"@admin:old.example": 100},
    "!repaired:old.example": {
        "@admin:new.example": 100,
        TARGET: 100,
    },
}
RATE_LIMITED = set()


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

    def do_GET(self):
        prefix = "/_synapse/admin/v1/rooms/"
        suffix = "/state"
        if not self.path.startswith(prefix) or not self.path.endswith(suffix):
            self.respond(404, {"errcode": "M_NOT_FOUND"})
            return
        room_id = unquote(self.path[len(prefix) : -len(suffix)])
        users = ROOMS.get(room_id)
        if users is None:
            self.respond(404, {"errcode": "M_NOT_FOUND", "error": "Unknown room"})
            return
        self.respond(
            200,
            {
                "state": [
                    {
                        "type": "m.room.power_levels",
                        "state_key": "",
                        "content": {"users_default": 0, "users": users},
                    }
                ]
            },
        )

    def do_POST(self):
        prefix = "/_synapse/admin/v1/rooms/"
        suffix = "/make_room_admin"
        if not self.path.startswith(prefix) or not self.path.endswith(suffix):
            self.respond(404, {"errcode": "M_NOT_FOUND"})
            return
        room_id = unquote(self.path[len(prefix) : -len(suffix)])
        users = ROOMS.get(room_id)
        if users is None:
            self.respond(404, {"errcode": "M_NOT_FOUND", "error": "Unknown room"})
            return
        if room_id == "!repairable:old.example" and room_id not in RATE_LIMITED:
            RATE_LIMITED.add(room_id)
            self.respond(429, {"errcode": "M_LIMIT_EXCEEDED", "retry_after_ms": 1})
            return
        if room_id == "!blocked:old.example":
            self.respond(400, {"errcode": "M_UNKNOWN", "error": "No local admin user in room"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length))
        users[payload["user_id"]] = 100
        self.respond(200, {})


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
!repaired:old.example
EOF

common_env=(
  "SYNAPSE_URL=http://127.0.0.1:$port"
  "ACCESS_TOKEN=test-token"
  "TARGET_USER_ID=@target:new.example"
  "REQUEST_DELAY_SECONDS=0"
)

env "${common_env[@]}" "$repair_script" inventory "$tmpdir/rooms" >"$tmpdir/inventory"
grep -F $'!repairable:old.example\t0\tneeds-repair' "$tmpdir/inventory" >/dev/null ||
  fail "repairable room was not detected"
grep -F $'!blocked:old.example\t0\tneeds-repair' "$tmpdir/inventory" >/dev/null ||
  fail "blocked room was not detected"
grep -F $'!repaired:old.example\t100\tadmin' "$tmpdir/inventory" >/dev/null ||
  fail "repaired room was not detected"

printf '%s\n' '!repairable:old.example' >"$tmpdir/repairable"
env "${common_env[@]}" "$repair_script" repair "$tmpdir/repairable" >"$tmpdir/repaired"
grep -F $'!repairable:old.example\t100\trepaired' "$tmpdir/repaired" >/dev/null ||
  fail "repairable room was not repaired and verified"

printf '%s\n' '!blocked:old.example' >"$tmpdir/blocked"
if env "${common_env[@]}" "$repair_script" repair "$tmpdir/blocked" >"$tmpdir/blocked-output"; then
  fail "room without a current local admin unexpectedly succeeded"
fi
grep -F $'!blocked:old.example\t0\tno-local-admin' "$tmpdir/blocked-output" >/dev/null ||
  fail "room without a local admin was not classified"

echo "Matrix migrated-room admin repair checks passed."
