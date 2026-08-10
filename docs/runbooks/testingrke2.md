# Testing RKE2 Overlay

`overlays/testingrke2` is the GitOps entry point for the local three-node RKE2
VM lab on `tux-h4xx-01`.

## Layering

The overlay imports `overlays/testing-srv3` and applies only RKE2-lab deltas:

- unique cluster identity and public-host suffix
- unique backup generations and server names
- Ceph removal
- three local Longhorn nodes
- public DNS and Cloudflare Tunnel suspension
- initial suspension of stateful or resource-heavy applications

This keeps testing and RKE2 validation aligned without copying application
definitions. Changes made to the regular testing overlay therefore reach the
RKE2 render automatically.

## Secrets

The initial lab inherits the encrypted `testing-srv3` secrets Kustomization.
`testingrke2-01` has the corresponding Flux SOPS key. This avoids duplicating
the encrypted secret set while the cluster is short-lived.

Do not enable stateful applications until their OIDC redirect URIs, DNS names,
backup generations, object-storage buckets, and external storage targets are
specific to `testingrke2`.

## Validation

```bash
scripts/verify-testingrke2-overlay.sh
```

The test renders:

- the root overlay
- nested Flux Kustomizations
- namespaces
- Longhorn node configuration

It also verifies that public-DNS safeguards remain enabled, Ceph is removed,
Flux paths point back to `testingrke2`, and exactly three Longhorn nodes are
declared.

## Enabling Workloads

Override the relevant value in `overlays/testingrke2/cluster-patch.yaml` and
reconcile the cluster:

```bash
KUBECONFIG=~/.kube/testingrke2.yaml flux reconcile source git flux-cluster
KUBECONFIG=~/.kube/testingrke2.yaml flux reconcile kustomization testingrke2
```

Keep `cloudflared_suspend` and `external_dns_suspend` set to `"true"` unless
the lab receives separate Cloudflare credentials and non-conflicting DNS
ownership.
