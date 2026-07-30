#!/usr/bin/env python3

import argparse
import concurrent.futures
import json
import random
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


class RateGate:
    def __init__(self):
        self._lock = threading.Lock()
        self._blocked_until = 0.0

    def wait(self):
        with self._lock:
            delay = self._blocked_until - time.monotonic()
        if delay > 0:
            time.sleep(delay)

    def block(self, delay):
        with self._lock:
            self._blocked_until = max(
                self._blocked_until,
                time.monotonic() + delay,
            )


class MatrixClient:
    def __init__(self, base_url, token):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.rate_gate = RateGate()

    def request(self, method, path, body=None):
        for attempt in range(12):
            self.rate_gate.wait()
            data = None
            headers = {"Authorization": f"Bearer {self.token}"}
            if body is not None:
                data = json.dumps(body).encode()
                headers["Content-Type"] = "application/json"
            request = urllib.request.Request(
                f"{self.base_url}{path}",
                data=data,
                headers=headers,
                method=method,
            )
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    payload = response.read()
                    return json.loads(payload) if payload else {}
            except urllib.error.HTTPError as error:
                if error.code != 429 or attempt == 11:
                    raise
                retry_after = self._retry_after(error, attempt)
                self.rate_gate.block(retry_after)
                time.sleep(random.uniform(0.05, 0.35))
        raise RuntimeError("rate-limit retry loop exhausted")

    @staticmethod
    def _retry_after(error, attempt):
        try:
            payload = json.loads(error.read())
        except (json.JSONDecodeError, UnicodeDecodeError):
            payload = {}
        retry_after_ms = payload.get("retry_after_ms")
        if retry_after_ms is not None:
            return min(max(float(retry_after_ms) / 1000, 0.25), 60)
        retry_after = error.headers.get("Retry-After")
        if retry_after:
            return min(max(float(retry_after), 0.25), 60)
        return min(2**attempt, 30)


def encoded(value):
    return urllib.parse.quote(value, safe="")


def state_path(room_id, event_type, state_key=""):
    return (
        f"/_matrix/client/v3/rooms/{encoded(room_id)}/state/"
        f"{encoded(event_type)}/{encoded(state_key)}"
    )


def read_candidates(path):
    candidates = []
    seen = set()
    with open(path, encoding="utf-8") as handle:
        for raw_line in handle:
            room_id = raw_line.strip()
            if not room_id or room_id.startswith("#"):
                continue
            if not room_id.startswith("!"):
                raise ValueError(f"invalid Matrix room ID: {room_id!r}")
            if room_id not in seen:
                candidates.append(room_id)
                seen.add(room_id)
    return candidates


def membership(client, room_id, user_id):
    return client.request(
        "GET",
        state_path(room_id, "m.room.member", user_id),
    ).get("membership")


def room_name(client, room_id):
    try:
        content = client.request(
            "GET",
            state_path(room_id, "m.room.name"),
        )
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return ""
        raise
    return content.get("name") or ""


def power_levels(client, room_id, retired_user, replacement_user):
    try:
        content = client.request(
            "GET",
            state_path(room_id, "m.room.power_levels"),
        )
    except urllib.error.HTTPError as error:
        if error.code == 404:
            content = {}
        else:
            raise
    users_default = int(content.get("users_default", 0))
    users = content.get("users") or {}
    return (
        int(users.get(retired_user, users_default)),
        int(users.get(replacement_user, users_default)),
    )


def audit_room(
    client,
    room_id,
    joined_rooms,
    direct_rooms,
    retired_user,
    replacement_user,
):
    if room_id not in joined_rooms:
        return "already-left"
    if room_id not in direct_rooms:
        return "not-in-retired-m-direct"
    if membership(client, room_id, replacement_user) != "join":
        return "replacement-not-joined"
    if room_name(client, room_id):
        return "explicit-room-name"
    retired_power, replacement_power = power_levels(
        client,
        room_id,
        retired_user,
        replacement_user,
    )
    if replacement_power < retired_power:
        return (
            "replacement-power-too-low"
            f"-{replacement_power}-lt-{retired_power}"
        )
    return "ready"


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Audit and retire an old Matrix account from exact migrated "
            "direct-message rooms through the supported client API."
        )
    )
    parser.add_argument("rooms")
    parser.add_argument("--retired-user", required=True)
    parser.add_argument("--replacement-user", required=True)
    parser.add_argument("--access-token-file", required=True)
    parser.add_argument(
        "--synapse-url",
        default="http://127.0.0.1:8008",
    )
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    candidates = read_candidates(args.rooms)
    with open(args.access_token_file, encoding="utf-8") as handle:
        token = handle.read().strip()
    if not token:
        raise RuntimeError("access token file is empty")

    client = MatrixClient(args.synapse_url, token)
    whoami = client.request("GET", "/_matrix/client/v3/account/whoami")
    if whoami.get("user_id") != args.retired_user:
        raise RuntimeError(
            "access token belongs to "
            f"{whoami.get('user_id')!r}, not {args.retired_user!r}"
        )

    joined_rooms = set(
        client.request("GET", "/_matrix/client/v3/joined_rooms").get(
            "joined_rooms", []
        )
    )
    direct_data = client.request(
        "GET",
        (
            f"/_matrix/client/v3/user/{encoded(args.retired_user)}"
            "/account_data/m.direct"
        ),
    )
    direct_rooms = {
        room_id
        for room_ids in direct_data.values()
        if isinstance(room_ids, list)
        for room_id in room_ids
    }

    statuses = {}
    for room_id in candidates:
        try:
            statuses[room_id] = audit_room(
                client,
                room_id,
                joined_rooms,
                direct_rooms,
                args.retired_user,
                args.replacement_user,
            )
        except urllib.error.HTTPError as error:
            statuses[room_id] = f"audit-http-{error.code}"
        except Exception as error:
            statuses[room_id] = f"audit-error-{type(error).__name__}"

    ready = [
        room_id
        for room_id, status in statuses.items()
        if status == "ready"
    ]
    already_left = [
        room_id
        for room_id, status in statuses.items()
        if status == "already-left"
    ]
    blocked = [
        (room_id, status)
        for room_id, status in statuses.items()
        if status not in {"ready", "already-left"}
    ]
    print(
        f"mode={'apply' if args.apply else 'audit'} "
        f"candidates={len(candidates)} ready={len(ready)} "
        f"already_left={len(already_left)} blocked={len(blocked)}"
    )
    for room_id, status in blocked:
        print(f"blocked|{room_id}|{status}")

    if not args.apply:
        return 0 if not blocked else 2

    def leave(room_id):
        try:
            client.request(
                "POST",
                f"/_matrix/client/v3/rooms/{encoded(room_id)}/leave",
                {},
            )
            return room_id, "left"
        except urllib.error.HTTPError as error:
            return room_id, f"leave-http-{error.code}"
        except Exception as error:
            return room_id, f"leave-error-{type(error).__name__}"

    results = []
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=max(1, args.workers)
    ) as executor:
        futures = [executor.submit(leave, room_id) for room_id in ready]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())

    failed_leaves = [
        (room_id, status)
        for room_id, status in results
        if status != "left"
    ]
    joined_after = set(
        client.request("GET", "/_matrix/client/v3/joined_rooms").get(
            "joined_rooms", []
        )
    )
    still_joined = [
        room_id
        for room_id in ready
        if room_id in joined_after
    ]
    print(
        f"submitted={len(ready)} "
        f"left={len(results) - len(failed_leaves)} "
        f"failed={len(failed_leaves)} "
        f"still_joined={len(still_joined)}"
    )
    for room_id, status in failed_leaves:
        print(f"error|{room_id}|{status}")
    for room_id in still_joined:
        print(f"remaining|{room_id}")

    return 0 if not blocked and not failed_leaves and not still_joined else 3


if __name__ == "__main__":
    sys.exit(main())
