#!/usr/bin/env bash
set -euo pipefail

context="${KUBECONFIG_CONTEXT:-homelab-prod}"
namespace="${FLUX_NAMESPACE:-flux-system}"

repo_root="$(git rev-parse --show-toplevel)"
secret_file="$repo_root/overlays/homelab/secrets/github-read-flux-cluster.yaml"

if [ ! -f "$secret_file" ]; then
  echo "missing secret file: $secret_file" >&2
  exit 1
fi

echo "Applying flux-cluster GitHub read secret to $context/$namespace"
sops -d "$secret_file" | kubectl --context "$context" -n "$namespace" apply -f -

echo "Patching GitRepository/flux-cluster to use github-read-flux-cluster"
kubectl --context "$context" -n "$namespace" patch gitrepository flux-cluster \
  --type=merge \
  --patch '{"spec":{"secretRef":{"name":"github-read-flux-cluster"}}}'

if command -v flux >/dev/null 2>&1; then
  flux --context "$context" -n "$namespace" reconcile source git flux-cluster
fi
