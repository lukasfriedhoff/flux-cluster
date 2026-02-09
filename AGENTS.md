# Flux-Cluster Repo Agent Notes

- this repo should not contain any apps or helm releases. instead it sources git repos like flux-apps and configures them
- base/configs/**/pre contains resources that must be present before rollout, like helm values and so on
- base/configs/**/post contains resources that need crds to be present and should be rolled out after the app itself, like storage classes for ceph
- helm values should be merged from sane defaults in flux-apps repo with cluster specific config via this repo. therefore base-config.yaml is used and merges with a cluster specific overlay cluster-patch.yaml
- flux post build kustomizations should be used for variables like delegating domain
- always use conventional commits
