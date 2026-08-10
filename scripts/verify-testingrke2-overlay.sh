#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
overlay="${repo_root}/overlays/testingrke2"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

for command in flux kustomize yq; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$command" >&2
    exit 1
  }
done

kustomize build "$overlay" >"${work_dir}/root.yaml"
kustomize build "${overlay}/kustomizations" >"${work_dir}/kustomizations.yaml"
kustomize build "${overlay}/namespaces" >"${work_dir}/namespaces.yaml"
kustomize build "${overlay}/longhorn-node-config" >"${work_dir}/longhorn.yaml"

yq -r '
  select(.kind == "ConfigMap" and .metadata.name == "base-config")
  | .data
  | to_entries[]
  | .key + "=" + (.value | @sh)
' "${work_dir}/root.yaml" >"${work_dir}/base-config.env"

set -a
# shellcheck disable=SC1091
source "${work_dir}/base-config.env"
set +a

for manifest in kustomizations namespaces longhorn; do
  flux envsubst --strict <"${work_dir}/${manifest}.yaml" >"${work_dir}/${manifest}-resolved.yaml"
done

grep -Fq 'cluster_name: testingrke2' "${work_dir}/root.yaml"
grep -Fq 'public_host_suffix: -testingrke2' "${work_dir}/root.yaml"
grep -Fq 'cloudflared_suspend: "true"' "${work_dir}/root.yaml"
grep -Fq 'external_dns_suspend: "true"' "${work_dir}/root.yaml"
grep -Fq 'media_suspend: "true"' "${work_dir}/root.yaml"
grep -Fq 'path: ./overlays/testingrke2/kustomizations/' "${work_dir}/root.yaml"
grep -Fq 'path: ./overlays/testingrke2/namespaces/' "${work_dir}/root.yaml"
grep -Fq 'path: ./overlays/testing-srv3/secrets/' "${work_dir}/root.yaml"
grep -Fq 'suspend: true' "${work_dir}/kustomizations-resolved.yaml"

if grep -Fq 'name: ceph-csi' "${work_dir}/namespaces-resolved.yaml"; then
  printf 'testingrke2 must not render the Ceph CSI namespace\n' >&2
  exit 1
fi

for index in 01 02 03; do
  grep -Fq "name: testingrke2-${index}" "${work_dir}/longhorn-resolved.yaml"
done

node_count="$(grep -c '^kind: Node$' "${work_dir}/longhorn-resolved.yaml")"
if [[ "$node_count" -ne 3 ]]; then
  printf 'expected 3 Longhorn nodes, got %s\n' "$node_count" >&2
  exit 1
fi

printf 'testingrke2 overlay render checks passed.\n'
