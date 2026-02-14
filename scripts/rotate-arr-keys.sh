#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd git
require_cmd rg
require_cmd sops
require_cmd python
require_cmd flux
require_cmd kubectl

root="$(git rev-parse --show-toplevel)"
cd "$root"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "working tree is dirty; commit or stash before rotating keys" >&2
  exit 1
fi

secrets_dir="$root/overlays/homelab/secrets"
arr_keys="$secrets_dir/arr-api-keys.yaml"
recyclarr_keys="$secrets_dir/recyclarr-secrets.yaml"
buildarr_keys="$secrets_dir/buildarr-secret.yaml"

if [[ ! -f "$recyclarr_keys" ]]; then
  echo "missing file: $recyclarr_keys" >&2
  exit 1
fi

recipient="$(rg -o 'age1[0-9a-z]+' "$recyclarr_keys" | head -n1 || true)"
if [[ -z "$recipient" ]]; then
  echo "failed to find age recipient in $recyclarr_keys" >&2
  exit 1
fi

export SOPS_AGE_RECIPIENT="$recipient"

python - <<'PY'
from __future__ import annotations
import secrets
import subprocess
import tempfile
import os
import re
from pathlib import Path

root = Path(".")
files = {
    "overlays/homelab/secrets/arr-api-keys.yaml": "arr",
    "overlays/homelab/secrets/recyclarr-secrets.yaml": "recyclarr",
    "overlays/homelab/secrets/buildarr-secret.yaml": "buildarr",
}

sonarr_key = secrets.token_hex(16)
radarr_key = secrets.token_hex(16)
recipient = os.environ["SOPS_AGE_RECIPIENT"]

def replace_or_fail(text: str, pattern: str, value: str) -> str:
    if not re.search(pattern, text, flags=re.M):
        raise SystemExit(f"pattern not found: {pattern!r}")
    return re.sub(pattern, lambda m: m.group(1) + value, text, flags=re.M)

def load_sops(path: Path) -> str:
    return subprocess.check_output(["sops", "-d", str(path)], text=True)

def write_sops(path: Path, plaintext: str) -> None:
    fd, tmp = tempfile.mkstemp(prefix="sops-plain-", suffix=".yaml")
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(plaintext)
        with open(path, "w") as out:
            subprocess.run(
                [
                    "sops",
                    "--encrypt",
                    "--age",
                    recipient,
                    "--input-type",
                    "yaml",
                    "--output-type",
                    "yaml",
                    tmp,
                ],
                check=True,
                stdout=out,
            )
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)

for rel, kind in files.items():
    path = root / rel
    plaintext = load_sops(path)
    if kind in ("arr", "recyclarr"):
        plaintext = replace_or_fail(plaintext, r"(^\\s*sonarr_api_key:\\s*)\\S+", sonarr_key)
        plaintext = replace_or_fail(plaintext, r"(^\\s*radarr_api_key:\\s*)\\S+", radarr_key)
    elif kind == "buildarr":
        plaintext = replace_or_fail(
            plaintext, r"(^\\s*sonarr:\\s*\\n\\s*api_key:\\s*)\\S+", sonarr_key
        )
        plaintext = replace_or_fail(
            plaintext, r"(^\\s*radarr:\\s*\\n\\s*api_key:\\s*)\\S+", radarr_key
        )
    write_sops(path, plaintext)
PY

git add "$arr_keys" "$recyclarr_keys" "$buildarr_keys"
git commit -m "chore(media): rotate arr api keys"
git push

flux reconcile source git flux-cluster -n flux-system
flux reconcile kustomization secrets -n flux-system
flux reconcile kustomization media-app -n flux-system

kubectl -n media rollout restart deploy/sonarr deploy/radarr
kubectl -n media rollout status deploy/sonarr --timeout=180s
kubectl -n media rollout status deploy/radarr --timeout=180s

ts="$(date +%Y%m%d%H%M%S)"
recyclarr_job="recyclarr-manual-$ts"
buildarr_job="buildarr-manual-$ts"

kubectl -n media create job --from=cronjob/recyclarr "$recyclarr_job"
kubectl -n media create job --from=cronjob/buildarr "$buildarr_job"

kubectl -n media wait --for=condition=complete "job/$recyclarr_job" --timeout=180s
kubectl -n media wait --for=condition=complete "job/$buildarr_job" --timeout=180s

kubectl -n media logs "job/$recyclarr_job"
kubectl -n media logs "job/$buildarr_job"

kubectl -n media delete "job/$recyclarr_job" "job/$buildarr_job"
