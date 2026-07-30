#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
clear_script="$repo_root/scripts/clear-matrix-migrated-room-names.sh"

fail() {
  echo "verify-matrix-migrated-room-name-clear: $*" >&2
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

TOKEN_USER = "@rollback:new.example"
ROOMS = {
    "!exact:old.example": {
        "event_id": "$repair-event",
        "sender": "@migration_name_repair_1:new.example",
        "name": "SophieEntropie",
        "membership": "join",
    },
    "!left:old.example": {
        "event_id": "$left-event",
        "sender": "@migration_name_repair_1:new.example",
        "name": "Jens",
        "membership": "leave",
    },
    "!changed:old.example": {
        "event_id": "$user-event",
        "sender": "@sophie:old.example",
        "name": "Lukas",
        "membership": "join",
    },
    "!empty:old.example": {
        "event_id": "$clear-event",
        "sender": TOKEN_USER,
        "name": "",
        "membership": "leave",
    },
}
RATE_LIMITED = set()
UNSAFE_REQUESTS = []


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
        if self.path == "/_matrix/client/v3/account/whoami":
            self.respond(200, {"user_id": TOKEN_USER, "is_guest": False})
            return

        if self.path == "/_test/unsafe":
            self.respond(200, {"requests": UNSAFE_REQUESTS})
            return

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
                        "type": "m.room.name",
                        "state_key": "",
                        "event_id": room["event_id"],
                        "sender": room["sender"],
                        "content": {"name": room["name"]},
                    },
                    {
                        "type": "m.room.member",
                        "state_key": TOKEN_USER,
                        "event_id": "$membership",
                        "sender": TOKEN_USER,
                        "content": {"membership": room["membership"]},
                    },
                ]
            },
        )

    def do_PUT(self):
        prefix = "/_matrix/client/v3/rooms/"
        suffix = "/state/m.room.name"
        if not self.path.startswith(prefix) or not self.path.endswith(suffix):
            UNSAFE_REQUESTS.append(["PUT", self.path])
            self.respond(500, {"error": "unsafe request"})
            return

        room_id = self.room_from_path(prefix, suffix)
        room = ROOMS.get(room_id)
        if room is None:
            self.respond(404, {"errcode": "M_NOT_FOUND"})
            return
        if room_id == "!exact:old.example" and room_id not in RATE_LIMITED:
            RATE_LIMITED.add(room_id)
            self.respond(429, {"errcode": "M_LIMIT_EXCEEDED", "retry_after_ms": 1})
            return
        if room["membership"] != "join":
            self.respond(403, {"errcode": "M_FORBIDDEN", "error": "Not joined"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length))
        if payload != {"name": ""}:
            UNSAFE_REQUESTS.append(["PUT", self.path, payload])
            self.respond(500, {"error": "non-empty name"})
            return

        room["event_id"] = "$cleared-event"
        room["sender"] = TOKEN_USER
        room["name"] = ""
        self.respond(200, {"event_id": "$cleared-event"})

    def do_POST(self):
        UNSAFE_REQUESTS.append(["POST", self.path])
        self.respond(500, {"error": "unsafe request"})


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
!exact:old.example	$repair-event	@migration_name_repair_1:new.example	SophieEntropie
!left:old.example	$left-event	@migration_name_repair_1:new.example	Jens
!changed:old.example	$repair-event	@migration_name_repair_1:new.example	Sophie
!empty:old.example	$repair-event	@migration_name_repair_1:new.example	Former title
EOF

common_env=(
  "SYNAPSE_URL=http://127.0.0.1:$port"
  "ACCESS_TOKEN=test-token"
  "REQUEST_DELAY_SECONDS=0"
)

env "${common_env[@]}" "$clear_script" inventory "$tmpdir/rooms" >"$tmpdir/inventory"
grep -F $'!exact:old.example\tSophieEntropie\t$repair-event\t@migration_name_repair_1:new.example\tSophieEntropie\tjoin\tneeds-clear\t-' "$tmpdir/inventory" >/dev/null ||
  fail "exact migration event was not marked for clearing"
grep -F $'!left:old.example\tJens\t$left-event\t@migration_name_repair_1:new.example\tJens\tleave\tneeds-clear\t-' "$tmpdir/inventory" >/dev/null ||
  fail "left-room migration event was not inventoried"
grep -F $'!changed:old.example\tSophie\t$user-event\t@sophie:old.example\tLukas\tjoin\tprotected-state-drift\t-' "$tmpdir/inventory" >/dev/null ||
  fail "participant-modified name was not protected"
grep -F $'!empty:old.example\tFormer title\t$clear-event\t@rollback:new.example\t<none>\tleave\talready-clear\t-' "$tmpdir/inventory" >/dev/null ||
  fail "empty room name was not recognized"

if env "${common_env[@]}" "$clear_script" apply "$tmpdir/rooms" >"$tmpdir/applied"; then
  fail "apply unexpectedly succeeded despite a matching left room"
fi
grep -F $'!exact:old.example\tSophieEntropie\t$cleared-event\t@rollback:new.example\t<none>\tjoin\tcleared\t-' "$tmpdir/applied" >/dev/null ||
  fail "exact migration event was not cleared"
grep -F $'!left:old.example\tJens\t$left-event\t@migration_name_repair_1:new.example\tJens\tleave\tblocked-not-joined\t-' "$tmpdir/applied" >/dev/null ||
  fail "left room was not blocked"
grep -F $'!changed:old.example\tSophie\t$user-event\t@sophie:old.example\tLukas\tjoin\tprotected-state-drift\t-' "$tmpdir/applied" >/dev/null ||
  fail "participant-modified name was overwritten"
grep -F $'!empty:old.example\tFormer title\t$clear-event\t@rollback:new.example\t<none>\tleave\talready-clear\t-' "$tmpdir/applied" >/dev/null ||
  fail "already-clear room changed"

env "${common_env[@]}" "$clear_script" inventory "$tmpdir/rooms" >"$tmpdir/after"
grep -F $'!exact:old.example\tSophieEntropie\t$cleared-event\t@rollback:new.example\t<none>\tjoin\talready-clear\t-' "$tmpdir/after" >/dev/null ||
  fail "cleared state did not remain empty"

unsafe_count="$(
  curl --fail --silent "http://127.0.0.1:$port/_test/unsafe" |
    python3 -c 'import json, sys; print(len(json.load(sys.stdin)["requests"]))'
)"
[[ "$unsafe_count" == "0" ]] ||
  fail "tool attempted room creation, joining, invitation, power-level changes, or a non-empty name"

echo "matrix migrated room-name clear verification passed"
