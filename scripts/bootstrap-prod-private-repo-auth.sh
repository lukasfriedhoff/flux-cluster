#!/usr/bin/env bash
set -euo pipefail

context="${KUBECONFIG_CONTEXT:-homelab-prod}"
namespace="${FLUX_NAMESPACE:-flux-system}"

repo_root="$(git rev-parse --show-toplevel)"
secret_file="$repo_root/overlays/homelab/secrets/github-deploy-flux-cluster-prod.yaml"

if [ ! -f "$secret_file" ]; then
  echo "missing secret file: $secret_file" >&2
  exit 1
fi

echo "Applying flux-cluster GitHub deploy key to $context/$namespace"
sops -d "$secret_file" | kubectl --context "$context" -n "$namespace" apply -f -

echo "Patching GitRepository/flux-cluster to use its read-only deploy key"
kubectl --context "$context" -n "$namespace" patch gitrepository flux-cluster \
  --type=merge \
  --patch '{"spec":{"secretRef":{"name":"github-deploy-flux-cluster-prod"},"url":"ssh://git@github.com/lukasfriedhoff/flux-cluster.git"}}'

if command -v flux >/dev/null 2>&1; then
  flux --context "$context" -n "$namespace" reconcile source git flux-cluster
fi
