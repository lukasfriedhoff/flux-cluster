#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${repo_root}/overlays/homelab/longhorn-replica-policy/replica-policy.yaml"

fail() {
  printf '[longhorn-replica-policy-test] FAIL: %s\n' "$*" >&2
  exit 1
}

grep -q 'kind: ClusterRole' "$manifest" \
  || fail "policy must use cluster-scoped RBAC"
grep -q 'kind: ClusterRoleBinding' "$manifest" \
  || fail "policy must bind cluster-scoped RBAC"
grep -q 'persistentvolumes' "$manifest" \
  || fail "policy must inspect PersistentVolumes"
grep -q 'storageclasses' "$manifest" \
  || fail "policy must inspect StorageClasses"
grep -q "parameters.numberOfReplicas" "$manifest" \
  || fail "StorageClass numberOfReplicas must be the source of truth"
grep -q "longhorn\\\\.h4xx\\\\.io/replica-policy" "$manifest" \
  || fail "policy must support emergency disable annotations"
grep -q "longhorn\\\\.h4xx\\\\.io/replica-count" "$manifest" \
  || fail "policy must support explicit emergency replica overrides"
grep -q 'schedule: "\*/5 \* \* \* \*"' "$manifest" \
  || fail "policy must reconcile every five minutes"

if grep -q 'namespace != "media"' "$manifest"; then
  fail "media volumes must not be excluded from replica reconciliation"
fi

kustomize build "${repo_root}/overlays/homelab/longhorn-replica-policy" >/dev/null \
  || fail "replica policy overlay does not render"

printf '[longhorn-replica-policy-test] policy ok\n'
