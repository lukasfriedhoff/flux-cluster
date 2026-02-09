# Flux-Cluster Repo Agent Notes

- this repo should not contain any apps or helm releases. instead it sources git repos like flux-apps and configures them
- base/configs/**/pre contains resources that must be present before rollout, like helm values and so on
- base/configs/**/post contains resources that need crds to be present and should be rolled out after the app itself, like storage classes for ceph
- helm values should be merged from sane defaults in flux-apps repo with cluster specific config via this repo. therefore base-config.yaml is used and merges with a cluster specific overlay cluster-patch.yaml
- flux post build kustomizations should be used for variables like delegating domain
- always use conventional commits
- storage decisions:
  - Ceph RBD (block) for stateful single-writer workloads (Postgres, Valkey, small app data) due to performance and latency.
  - CephFS (filesystem) for shared RWX data that must be accessed by multiple pods (Nextcloud user data).
  - local-path only for dev/test or non-critical ephemeral data.
  - if scaling apps horizontally, ensure all writable paths use RWX (CephFS) or object storage.
