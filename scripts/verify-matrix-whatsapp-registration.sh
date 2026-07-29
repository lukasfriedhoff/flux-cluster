#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_overlays=(testing-srv3 staging-3vm homelab)
if (($#)); then
  overlays=("$@")
else
  overlays=("${default_overlays[@]}")
fi

fail() {
  echo "verify-matrix-whatsapp-registration: $*" >&2
  exit 1
}

command -v sops >/dev/null || fail "sops is required"
command -v python3 >/dev/null || fail "python3 is required"

umask 077
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

for overlay in "${overlays[@]}"; do
  secret="$repo_root/overlays/$overlay/secrets/matrix-whatsapp-config.yaml"
  registration="$tmpdir/$overlay-registration.yaml"

  [[ -f "$secret" ]] || fail "missing secret for overlay '$overlay'"
  sops -d --extract '["stringData"]["registration.yaml"]' "$secret" >"$registration"

  python3 - "$registration" "$overlay" <<'PY'
import pathlib
import re
import sys

registration_path = pathlib.Path(sys.argv[1])
overlay = sys.argv[2]
patterns = []

for line in registration_path.read_text().splitlines():
    match = re.match(r"^\s*-\s+regex:\s*(.+?)\s*$", line)
    if not match:
        continue
    pattern = match.group(1)
    if len(pattern) >= 2 and pattern[0] == pattern[-1] and pattern[0] in {"'", '"'}:
        pattern = pattern[1:-1]
    patterns.append(pattern)

ghost_patterns = [pattern for pattern in patterns if pattern.startswith("^@whatsapp_")]
bot_patterns = [pattern for pattern in patterns if pattern.startswith("^@whatsappbot:")]

if len(ghost_patterns) != 1:
    raise SystemExit(f"{overlay}: expected one WhatsApp ghost namespace, found {len(ghost_patterns)}")
if len(bot_patterns) != 1:
    raise SystemExit(f"{overlay}: expected one WhatsApp bot namespace, found {len(bot_patterns)}")

replacements = {
    "${cluster_environment}": "testing",
    "${delegating_domain}": "example.test",
    "${matrix_server_name}": "example.test",
}

def expand(pattern: str) -> str:
    for source, replacement in replacements.items():
        pattern = pattern.replace(source, replacement)
    return pattern

ghost_pattern = expand(ghost_patterns[0])
bot_pattern = expand(bot_patterns[0])
domain_pattern = ghost_pattern.rsplit(":", 1)[1].removesuffix("$")
domain = domain_pattern.replace(r"\.", ".")

ghost_regex = re.compile(ghost_pattern)
bot_regex = re.compile(bot_pattern)

expected = (
    f"@whatsapp_491234567890:{domain}",
    f"@whatsapp_lid-149417684398282:{domain}",
)
unexpected = (
    f"@whatsapp_alice:{domain}",
    f"@whatsapp_lid-alice:{domain}",
)

for user_id in expected:
    if ghost_regex.fullmatch(user_id) is None:
        raise SystemExit(f"{overlay}: namespace rejects required bridge user form")
for user_id in unexpected:
    if ghost_regex.fullmatch(user_id) is not None:
        raise SystemExit(f"{overlay}: namespace accepts an unrelated bridge user form")
if bot_regex.fullmatch(f"@whatsappbot:{domain}") is None:
    raise SystemExit(f"{overlay}: namespace rejects the WhatsApp bot")

print(f"{overlay}: WhatsApp phone, LID, and bot namespaces passed")
PY
done

echo "Matrix WhatsApp registration checks passed."
