# Template — encrypt with SOPS before use:
#   cp nextcloud-postgres-backup-credentials.yaml.tpl nextcloud-postgres-backup-credentials.yaml
#   # fill in values (same external S3 as longhorn-backup-target)
#   sops --encrypt --in-place nextcloud-postgres-backup-credentials.yaml
# Then add nextcloud-postgres-backup-credentials.yaml to kustomization.yaml
# and set nextcloud_postgres_backup_endpoint_url in cluster-patch.yaml.
apiVersion: v1
kind: Secret
metadata:
  name: nextcloud-postgres-backup-credentials
  namespace: nextcloud
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "REPLACE_ME"
  AWS_SECRET_ACCESS_KEY: "REPLACE_ME"
