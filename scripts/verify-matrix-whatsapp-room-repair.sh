#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repair_script="$repo_root/scripts/repair-matrix-whatsapp-migrated-rooms.sh"

fail() {
  echo "verify-matrix-whatsapp-room-repair: $*" >&2
  exit 1
}

command -v python3 >/dev/null || fail "python3 is required"

umask 077
tmpdir="$(mktemp -d)"
server_pid=""
trap '[[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true; rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

ADMIN = "@lukasf:h4xx.io"
BRIDGE = "@whatsappbot:h4xx.io"
ROOMS = {
    "!repairable:old.example": {ADMIN: 100},
    "!insufficient:old.example": {ADMIN: 0},
    "!repaired:old.example": {ADMIN: 100, BRIDGE: 100},
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
        prefix = "/_matrix/client/v3/rooms/"
        suffix = "/state/m.room.power_levels"
        if not self.path.startswith(prefix) or not self.path.endswith(suffix):
            self.respond(404, {"errcode": "M_NOT_FOUND"})
            return
        room_id = unquote(self.path[len(prefix) : -len(suffix)])
        users = ROOMS.get(room_id)
        if users is None:
            self.respond(404, {"errcode": "M_NOT_FOUND", "error": "Unknown room"})
            return
        self.respond(200, {"users_default": 0, "users": users})

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
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length))
        if users.get(ADMIN, 0) < 100:
            self.respond(400, {"errcode": "M_UNKNOWN", "error": "No local admin user in room"})
            return
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
!insufficient:old.example
!repaired:old.example
EOF

common_env=(
  "SYNAPSE_URL=http://127.0.0.1:$port"
  "ACCESS_TOKEN=test-token"
  "REQUEST_DELAY_SECONDS=0"
)

env "${common_env[@]}" "$repair_script" inventory "$tmpdir/rooms" >"$tmpdir/inventory" || true
grep -F $'!repairable:old.example\t100\t0\trepairable' "$tmpdir/inventory" >/dev/null ||
  fail "repairable room was not detected"
grep -F $'!insufficient:old.example\t0\t0\tinsufficient-local-admin' "$tmpdir/inventory" >/dev/null ||
  fail "insufficient room was not detected"
grep -F $'!repaired:old.example\t100\t100\trepaired' "$tmpdir/inventory" >/dev/null ||
  fail "repaired room was not detected"

printf '%s\n' '!repairable:old.example' >"$tmpdir/repairable"
env "${common_env[@]}" "$repair_script" repair "$tmpdir/repairable" >"$tmpdir/repaired"
grep -F $'!repairable:old.example\t100\t100\trepaired' "$tmpdir/repaired" >/dev/null ||
  fail "repairable room was not repaired and verified"

echo "Matrix WhatsApp migrated-room repair checks passed."
