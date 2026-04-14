# Template — encrypt with SOPS before use:
#   cp immich-postgres-backup-credentials.yaml.tpl immich-postgres-backup-credentials.yaml
#   sops --encrypt --in-place immich-postgres-backup-credentials.yaml
# Then add immich-postgres-backup-credentials.yaml to kustomization.yaml
# and set immich_postgres_backup_endpoint_url in cluster-patch.yaml.
apiVersion: v1
kind: Secret
metadata:
  name: immich-postgres-backup-credentials
  namespace: immich
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "REPLACE_ME"
  AWS_SECRET_ACCESS_KEY: "REPLACE_ME"
  AWS_ENDPOINTS: "REPLACE_ME"
