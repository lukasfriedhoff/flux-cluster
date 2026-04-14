# Template — encrypt with SOPS before use:
#   cp matrix-postgres-backup-credentials.yaml.tpl matrix-postgres-backup-credentials.yaml
#   sops --encrypt --in-place matrix-postgres-backup-credentials.yaml
# Then add matrix-postgres-backup-credentials.yaml to kustomization.yaml
# and set matrix_postgres_backup_endpoint_url in cluster-patch.yaml.
apiVersion: v1
kind: Secret
metadata:
  name: matrix-postgres-backup-credentials
  namespace: matrix
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "REPLACE_ME"
  AWS_SECRET_ACCESS_KEY: "REPLACE_ME"
  AWS_ENDPOINTS: "REPLACE_ME"
