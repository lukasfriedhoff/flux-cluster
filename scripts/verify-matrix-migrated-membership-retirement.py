#!/usr/bin/env python3

import json
import pathlib
import subprocess
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


RETIRED_USER = "@old:old.example"
REPLACEMENT_USER = "@new:new.example"
SAFE_ROOM = "!safe:old.example"
UNSAFE_ROOM = "!unsafe:old.example"
NAMED_ROOM = "!named:old.example"
NOT_DIRECT_ROOM = "!not-direct:old.example"
LEFT_ROOM = "!left:old.example"


class MatrixFixture(BaseHTTPRequestHandler):
    joined = {
        SAFE_ROOM,
        UNSAFE_ROOM,
        NAMED_ROOM,
        NOT_DIRECT_ROOM,
    }
    leave_attempts = {}
    mutations = []

    def log_message(self, _format, *_args):
        return

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.unquote(self.path)
        if path == "/_matrix/client/v3/account/whoami":
            self.send_json(200, {"user_id": RETIRED_USER})
            return
        if path == "/_matrix/client/v3/joined_rooms":
            self.send_json(200, {"joined_rooms": sorted(self.joined)})
            return
        if path == (
            f"/_matrix/client/v3/user/{RETIRED_USER}"
            "/account_data/m.direct"
        ):
            self.send_json(
                200,
                {
                    "@partner:new.example": [
                        SAFE_ROOM,
                        UNSAFE_ROOM,
                        NAMED_ROOM,
                        LEFT_ROOM,
                    ]
                },
            )
            return
        prefix = "/_matrix/client/v3/rooms/"
        if path.startswith(prefix) and "/state/" in path:
            room_id, state = path[len(prefix) :].split("/state/", 1)
            if state.startswith(f"m.room.member/{REPLACEMENT_USER}"):
                self.send_json(200, {"membership": "join"})
                return
            if state == "m.room.name/":
                if room_id == NAMED_ROOM:
                    self.send_json(200, {"name": "Unsafe shared title"})
                else:
                    self.send_json(404, {"errcode": "M_NOT_FOUND"})
                return
            if state == "m.room.power_levels/":
                users = {
                    RETIRED_USER: 50,
                    REPLACEMENT_USER: 0 if room_id == UNSAFE_ROOM else 50,
                }
                self.send_json(200, {"users": users, "users_default": 0})
                return
        self.send_json(404, {"errcode": "M_NOT_FOUND"})

    def do_POST(self):
        path = urllib.parse.unquote(self.path)
        prefix = "/_matrix/client/v3/rooms/"
        if path.startswith(prefix) and path.endswith("/leave"):
            room_id = path[len(prefix) : -len("/leave")]
            self.mutations.append(path)
            self.leave_attempts[room_id] = self.leave_attempts.get(room_id, 0) + 1
            if room_id == SAFE_ROOM and self.leave_attempts[room_id] == 1:
                self.send_json(
                    429,
                    {
                        "errcode": "M_LIMIT_EXCEEDED",
                        "retry_after_ms": 10,
                    },
                )
                return
            self.joined.discard(room_id)
            self.send_json(200, {})
            return
        self.mutations.append(path)
        self.send_json(404, {"errcode": "M_NOT_FOUND"})


def run(command):
    return subprocess.run(
        command,
        text=True,
        capture_output=True,
        check=False,
    )


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    script = repo_root / "scripts" / "retire-matrix-migrated-direct-memberships.py"
    server = ThreadingHTTPServer(("127.0.0.1", 0), MatrixFixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        with tempfile.TemporaryDirectory() as temp_directory:
            temp_path = pathlib.Path(temp_directory)
            token_file = temp_path / "token"
            token_file.write_text("fixture-token\n", encoding="utf-8")
            all_rooms = temp_path / "all-rooms"
            all_rooms.write_text(
                "\n".join(
                    [
                        SAFE_ROOM,
                        UNSAFE_ROOM,
                        NAMED_ROOM,
                        NOT_DIRECT_ROOM,
                        LEFT_ROOM,
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            safe_rooms = temp_path / "safe-rooms"
            safe_rooms.write_text(
                f"{SAFE_ROOM}\n{LEFT_ROOM}\n",
                encoding="utf-8",
            )
            common = [
                str(script),
                "--retired-user",
                RETIRED_USER,
                "--replacement-user",
                REPLACEMENT_USER,
                "--access-token-file",
                str(token_file),
                "--synapse-url",
                f"http://127.0.0.1:{server.server_port}",
            ]

            audit = run([*common, str(all_rooms)])
            require(audit.returncode == 2, f"unexpected audit result: {audit}")
            require(
                "ready=1 already_left=1 blocked=3" in audit.stdout,
                f"unexpected audit summary: {audit.stdout}",
            )
            require(not MatrixFixture.mutations, "audit mutated Matrix state")

            apply = run([*common, "--apply", "--workers", "2", str(safe_rooms)])
            require(apply.returncode == 0, f"unexpected apply result: {apply}")
            require(
                "submitted=1 left=1 failed=0 still_joined=0" in apply.stdout,
                f"unexpected apply summary: {apply.stdout}",
            )
            require(
                MatrixFixture.leave_attempts.get(SAFE_ROOM) == 2,
                "429 leave response was not retried exactly once",
            )
            require(
                MatrixFixture.mutations
                == [
                    f"/_matrix/client/v3/rooms/{SAFE_ROOM}/leave",
                    f"/_matrix/client/v3/rooms/{SAFE_ROOM}/leave",
                ],
                f"unexpected Matrix mutations: {MatrixFixture.mutations}",
            )

            repeat = run([*common, "--apply", str(safe_rooms)])
            require(repeat.returncode == 0, f"repeat apply failed: {repeat}")
            require(
                "ready=0 already_left=2 blocked=0" in repeat.stdout,
                f"repeat apply was not idempotent: {repeat.stdout}",
            )
    finally:
        server.shutdown()
        server.server_close()

    print("matrix migrated membership retirement verification passed")


if __name__ == "__main__":
    main()
