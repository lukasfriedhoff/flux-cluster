# Flux-Cluster Repo Agent Notes

- this repo should not contain any apps or helm releases. instead it sources git repos like flux-apps and configures them
- base/configs/**/pre contains resources that must be present before rollout, like helm values and so on
- base/configs/**/post contains resources that need crds to be present and should be rolled out after the app itself, like storage classes for ceph
- helm values should be merged from sane defaults in flux-apps repo with cluster specific config via this repo. therefore base-config.yaml is used and merges with a cluster specific overlay cluster-patch.yaml
- flux post build kustomizations should be used for variables like delegating domain
- always use conventional commits
- keep sane defaults in `base/base-config.yaml`.
- only put per-cluster deltas in `overlays/<cluster>/cluster-patch.yaml`.
- if an overlay value equals base default, remove it from the overlay patch.
- when integrating an app from flux-apps, start from `flux-apps/examples/apps/<app>/flux-cluster-kustomization.yaml` and `base-config.defaults.yaml`.
- storage decisions:
  - in virtualized clusters (for example `testing-srv3`), use Longhorn classes:
    - `*-rwo-*` for stateful single-writer workloads (Postgres, Valkey, app configs).
    - `*-rwx-*` for shared RWX data (Nextcloud data, media shared volumes).
  - in non-virtualized clusters where Ceph is available, Ceph RBD/CephFS can still be used.
  - local-path only for dev/test or non-critical ephemeral data.
  - if scaling apps horizontally, ensure all writable paths use RWX storage or object storage.
- always check all kustomizations after changes and fix things if they are not ready
