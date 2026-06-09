#!/usr/bin/env bash
set -euo pipefail

context="${KUBECONTEXT:-homelab-testing}"
namespace="${NAMESPACE:-matrix-rewrite-test}"
source_host="${SOURCE_HOST:-docker-host}"
source_dir="${SOURCE_DIR:-/mnt/dockerstorage/matrix}"
old_server="${OLD_SERVER:-m.h4.ddnss.org}"
new_server="${NEW_SERVER:-matrix-testing.h4xx.io}"
work_dir="${WORK_DIR:-$PWD/.matrix-rewrite}"
storage_class="${STORAGE_CLASS:-testing-longhorn-rwo-1r}"
postgres_size="${POSTGRES_SIZE:-8Gi}"
media_size="${MEDIA_SIZE:-50Gi}"
synapse_image="${SYNAPSE_IMAGE:-matrixdotorg/synapse:latest}"
media_copy_batch_size="${MEDIA_COPY_BATCH_SIZE:-500}"

usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  dump-source       Dump source Synapse Postgres from docker-host into WORK_DIR.
  inventory-dump    Count old/new server-name strings in the SQL dump.
  scratch-up        Create an isolated Postgres + media scratch namespace.
  restore-db        Restore the source dump into scratch Postgres.
  repair-owner      Repair restored DB ownership for the synapse role.
  rewrite-db        Rewrite OLD_SERVER to NEW_SERVER in text/json/jsonb columns.
  copy-media        Copy source synapsemedia into scratch media PVC.
  deploy-synapse    Deploy a scratch Synapse against rewritten DB/media.
  validate          Show health, logs, and remaining DB/media references.
  delete-scratch    Delete the scratch namespace.
  all-db            Run dump-source, inventory-dump, scratch-up, restore-db, rewrite-db.

Environment:
  KUBECONTEXT=$context
  NAMESPACE=$namespace
  SOURCE_HOST=$source_host
  SOURCE_DIR=$source_dir
  OLD_SERVER=$old_server
  NEW_SERVER=$new_server
  WORK_DIR=$work_dir
  STORAGE_CLASS=$storage_class
  POSTGRES_SIZE=$postgres_size
  MEDIA_SIZE=$media_size
  SYNAPSE_IMAGE=$synapse_image
  MEDIA_COPY_BATCH_SIZE=$media_copy_batch_size
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "missing required binary: $1"
}

guard_namespace() {
  if [[ "$namespace" == "matrix" && "${ALLOW_LIVE_MATRIX:-}" != "true" ]]; then
    die "refusing to operate on live namespace matrix; set ALLOW_LIVE_MATRIX=true if you really mean it"
  fi
}

kubectl_ns() {
  kubectl --context="$context" -n "$namespace" "$@"
}

pod_for_app() {
  kubectl_ns get pod -l "app.kubernetes.io/name=$1" -o jsonpath='{.items[0].metadata.name}'
}

postgres_password_file() {
  printf '%s/postgres-password.txt' "$work_dir"
}

postgres_password() {
  cat "$(postgres_password_file)"
}

ensure_work_dir() {
  mkdir -p "$work_dir"
  if [[ ! -s "$(postgres_password_file)" ]]; then
    umask 077
    local password
    password="$(LC_ALL=C tr -dc 'A-Za-z0-9_+=' </dev/urandom | head -c 40 || true)"
    printf '%s' "$password" >"$(postgres_password_file)"
  fi
}

dump_source() {
  require_bin ssh
  ensure_work_dir
  local dump="$work_dir/synapse.dump"
  if [[ -s "$dump" && "${FORCE_DUMP:-}" != "true" ]]; then
    echo "Using existing source dump: $dump"
    ls -lh "$dump"
    return
  fi
  echo "Dumping source Synapse DB from $source_host:$source_dir to $dump"
  ssh "$source_host" "cd '$source_dir' && docker compose exec -T synapsedb pg_dump -U synapse -d synapse -Fc --no-owner --no-acl" >"$dump"
  test -s "$dump" || die "dump is empty: $dump"
  ls -lh "$dump"
}

inventory_dump() {
  ensure_work_dir
  local dump="$work_dir/synapse.dump"
  test -s "$dump" || die "missing dump: $dump"
  if ! command -v pg_restore >/dev/null 2>&1; then
    echo "Skipping dump inventory: pg_restore is not installed locally."
    return
  fi
  echo "Counting server-name strings in logical dump:"
  printf '  %-28s %s\n' "$old_server" "$(pg_restore -f - "$dump" | LC_ALL=C grep -aoF "$old_server" | wc -l)"
  printf '  %-28s %s\n' "$new_server" "$(pg_restore -f - "$dump" | LC_ALL=C grep -aoF "$new_server" | wc -l)"
}

scratch_up() {
  require_bin kubectl
  guard_namespace
  ensure_work_dir
  kubectl --context="$context" create namespace "$namespace" --dry-run=client -o yaml | kubectl --context="$context" apply -f -
  kubectl_ns create secret generic rewrite-postgres \
    --from-literal=POSTGRES_PASSWORD="$(postgres_password)" \
    --dry-run=client -o yaml | kubectl --context="$context" apply -f -
  cat <<EOF | kubectl --context="$context" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rewrite-postgres
  namespace: $namespace
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $storage_class
  resources:
    requests:
      storage: $postgres_size
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rewrite-media
  namespace: $namespace
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $storage_class
  resources:
    requests:
      storage: $media_size
---
apiVersion: v1
kind: Service
metadata:
  name: rewrite-postgres
  namespace: $namespace
spec:
  selector:
    app.kubernetes.io/name: rewrite-postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rewrite-postgres
  namespace: $namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: rewrite-postgres
  template:
    metadata:
      labels:
        app.kubernetes.io/name: rewrite-postgres
    spec:
      containers:
        - name: postgres
          image: postgres:18-alpine
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: rewrite-postgres
                  key: POSTGRES_PASSWORD
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: rewrite-postgres
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rewrite-tool
  namespace: $namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: rewrite-tool
  template:
    metadata:
      labels:
        app.kubernetes.io/name: rewrite-tool
    spec:
      containers:
        - name: tool
          image: alpine:3.20
          command: ["/bin/sh", "-c", "sleep infinity"]
          volumeMounts:
            - name: media
              mountPath: /media_store
      volumes:
        - name: media
          persistentVolumeClaim:
            claimName: rewrite-media
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rewrite-synapse-isolated
  namespace: $namespace
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: rewrite-synapse
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: rewrite-postgres
      ports:
        - protocol: TCP
          port: 5432
EOF
  kubectl_ns rollout status deploy/rewrite-postgres --timeout=180s
  kubectl_ns rollout status deploy/rewrite-tool --timeout=180s
}

restore_db() {
  require_bin kubectl
  guard_namespace
  ensure_work_dir
  local dump="$work_dir/synapse.dump"
  test -s "$dump" || die "missing dump: $dump"
  kubectl_ns exec deploy/rewrite-postgres -- sh -ceu "export PGPASSWORD='$(postgres_password)'; dropdb -h 127.0.0.1 -U postgres --if-exists synapse; dropuser -h 127.0.0.1 -U postgres --if-exists synapse; createuser -h 127.0.0.1 -U postgres synapse; psql -h 127.0.0.1 -U postgres -d postgres -c \"alter role synapse password '$(postgres_password)'\"; createdb -h 127.0.0.1 -U postgres -O synapse synapse"
  local postgres_pod
  postgres_pod="$(pod_for_app rewrite-postgres)"
  kubectl_ns cp "$dump" "$postgres_pod:/tmp/synapse.dump"
  kubectl_ns exec deploy/rewrite-postgres -- sh -ceu "export PGPASSWORD='$(postgres_password)'; pg_restore -h 127.0.0.1 -U postgres -d synapse --no-owner --no-acl /tmp/synapse.dump"
  repair_db_owner
}

repair_db_owner() {
  kubectl_ns exec deploy/rewrite-postgres -- sh -ceu "export PGPASSWORD='$(postgres_password)'; psql -h 127.0.0.1 -U postgres -d synapse <<'SQL'
alter database synapse owner to synapse;
do \$\$
declare
  item record;
begin
  for item in select schemaname, tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table %I.%I owner to synapse', item.schemaname, item.tablename);
  end loop;
  for item in select schemaname, sequencename from pg_sequences where schemaname = 'public' loop
    execute format('alter sequence %I.%I owner to synapse', item.schemaname, item.sequencename);
  end loop;
  for item in select n.nspname as schema_name, p.proname as function_name, pg_get_function_identity_arguments(p.oid) as args from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' loop
    execute format('alter function %I.%I(%s) owner to synapse', item.schema_name, item.function_name, item.args);
  end loop;
end
\$\$;
grant all privileges on all tables in schema public to synapse;
grant all privileges on all sequences in schema public to synapse;
SQL"
}

rewrite_db() {
  require_bin kubectl
  guard_namespace
  ensure_work_dir
  local sql="$work_dir/rewrite.sql"
  cat >"$sql" <<'SQL'
\set ON_ERROR_STOP on
create schema if not exists rewrite_experiment;
set session_replication_role = replica;

create or replace function rewrite_experiment.replace_server_name(old_value text, new_value text)
returns table(table_name text, column_name text, rows_changed bigint)
language plpgsql
as $$
declare
  item record;
  statement text;
begin
  for item in
    select c.table_schema, c.table_name, c.column_name, c.data_type, c.udt_name
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.data_type in ('text', 'character varying', 'character', 'json', 'jsonb')
  loop
    if item.data_type in ('json', 'jsonb') then
      statement := format(
        'update %I.%I set %I = replace(%I::text, %L, %L)::%s where %I::text like %L',
        item.table_schema,
        item.table_name,
        item.column_name,
        item.column_name,
        old_value,
        new_value,
        item.udt_name,
        item.column_name,
        '%' || old_value || '%'
      );
    else
      statement := format(
        'update %I.%I set %I = replace(%I, %L, %L) where %I like %L',
        item.table_schema,
        item.table_name,
        item.column_name,
        item.column_name,
        old_value,
        new_value,
        item.column_name,
        '%' || old_value || '%'
      );
    end if;

    execute statement;
    get diagnostics rows_changed = row_count;
    if rows_changed > 0 then
      table_name := item.table_schema || '.' || item.table_name;
      column_name := item.column_name;
      return next;
    end if;
  end loop;
end;
$$;

select * from rewrite_experiment.replace_server_name(:'old_server', :'new_server')
order by table_name, column_name;
set session_replication_role = origin;
SQL
  local postgres_pod
  postgres_pod="$(pod_for_app rewrite-postgres)"
  kubectl_ns cp "$sql" "$postgres_pod:/tmp/rewrite.sql"
  kubectl_ns exec deploy/rewrite-postgres -- sh -ceu "export PGPASSWORD='$(postgres_password)'; psql -h 127.0.0.1 -U postgres -d synapse -v old_server='$old_server' -v new_server='$new_server' -f /tmp/rewrite.sql"
}

copy_media() {
  require_bin ssh
  require_bin scp
  require_bin kubectl
  guard_namespace
  ensure_work_dir

  local manifest_dir="$work_dir/media-copy"
  local source_manifest="$manifest_dir/source.tsv"
  local destination_manifest="$manifest_dir/destination.tsv"
  local pending_list="$manifest_dir/pending.txt"
  local batch_dir="$manifest_dir/batches"
  mkdir -p "$manifest_dir"
  rm -rf "$batch_dir"
  mkdir -p "$batch_dir"

  echo "Building source media manifest from $source_host:$source_dir/synapsemedia"
  ssh "$source_host" "cd '$source_dir/synapsemedia' && find . -type f -printf '%P	%s\n'" \
    | LC_ALL=C sort >"$source_manifest"

  echo "Building destination media manifest from $namespace/rewrite-media"
  kubectl_ns exec deploy/rewrite-tool -- sh -c "du -ab /media_store | sed -n 's#^\([0-9][0-9]*\)[[:space:]]/media_store/\(.*\)#\2	\1#p'" \
    | LC_ALL=C sort >"$destination_manifest"

  awk -F '\t' '
    NR == FNR {
      destination_size[$1] = $2
      next
    }
    !(($1 in destination_size) && destination_size[$1] == $2) {
      print $1
    }
  ' "$destination_manifest" "$source_manifest" >"$pending_list"

  local source_count destination_count pending_count pending_bytes
  source_count="$(wc -l <"$source_manifest" | tr -d ' ')"
  destination_count="$(wc -l <"$destination_manifest" | tr -d ' ')"
  pending_count="$(wc -l <"$pending_list" | tr -d ' ')"
  pending_bytes="$(awk -F '\t' 'NR == FNR { pending[$1] = 1; next } $1 in pending { total += $2 } END { print total + 0 }' "$pending_list" "$source_manifest")"

  echo "Source files: $source_count"
  echo "Destination files: $destination_count"
  echo "Pending files: $pending_count"
  echo "Pending bytes: $pending_bytes"

  if [[ "$pending_count" == "0" ]]; then
    echo "Media copy is already complete."
    kubectl_ns exec deploy/rewrite-tool -- du -sh /media_store || true
    return
  fi

  split -d -a 5 -l "$media_copy_batch_size" "$pending_list" "$batch_dir/batch-"

  local batch batch_number batch_count remote_list
  batch_number=0
  batch_count="$(find "$batch_dir" -type f | wc -l | tr -d ' ')"
  for batch in "$batch_dir"/batch-*; do
    [[ -s "$batch" ]] || continue
    batch_number=$((batch_number + 1))
    remote_list="/tmp/matrix-media-${namespace}-$(date +%s)-${batch_number}.list"
    echo "Copying media batch $batch_number/$batch_count ($(wc -l <"$batch" | tr -d ' ') files)"
    scp -q "$batch" "$source_host:$remote_list"
    set +e
    ssh "$source_host" "cd '$source_dir/synapsemedia' && tar -cpf - -T '$remote_list'; status=\$?; rm -f '$remote_list'; exit \$status" \
      | kubectl_ns exec -i deploy/rewrite-tool -- tar -C /media_store -xpf -
    local batch_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${batch_status[0]}" != "0" || "${batch_status[1]}" != "0" ]]; then
      die "media batch $batch_number failed: source ssh/tar=${batch_status[0]}, destination kubectl/tar=${batch_status[1]}"
    fi
    echo "Finished media batch $batch_number/$batch_count"
  done

  echo "Media copy pass complete."
  kubectl_ns exec deploy/rewrite-tool -- du -sh /media_store || true
}

deploy_synapse() {
  require_bin kubectl
  guard_namespace
  ensure_work_dir
  local signing_key_file="$work_dir/homeserver.signing.key"
  if [[ ! -s "$signing_key_file" ]]; then
    require_bin ssh
    ssh "$source_host" "cat '$source_dir/synapseconfig/'*.signing.key" >"$signing_key_file"
  fi
  kubectl_ns create secret generic rewrite-synapse-config \
    --from-file=homeserver.signing.key="$signing_key_file" \
    --dry-run=client -o yaml | kubectl --context="$context" apply -f -
  cat <<EOF | kubectl --context="$context" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: rewrite-synapse-config
  namespace: $namespace
data:
  homeserver.yaml: |
    server_name: "$new_server"
    public_baseurl: "https://$new_server"
    pid_file: /tmp/homeserver.pid
    web_client_location: false
    listeners:
      - port: 8008
        tls: false
        type: http
        x_forwarded: true
        resources:
          - names: [client, federation]
            compress: false
    database:
      name: psycopg2
      allow_unsafe_locale: true
      args:
        user: synapse
        password: "$(postgres_password)"
        database: synapse
        host: rewrite-postgres
        cp_min: 5
        cp_max: 10
    media_store_path: /media_store
    signing_key_path: /config/homeserver.signing.key
    macaroon_secret_key: "$(postgres_password)-macaroon"
    form_secret: "$(postgres_password)-form"
    registration_shared_secret: "$(postgres_password)-registration"
    trusted_key_servers: []
    suppress_key_server_warning: true
    report_stats: false
    enable_registration: false
    log_config: /config/log.config
  log.config: |
    version: 1
    formatters:
      precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'
    handlers:
      console:
        class: logging.StreamHandler
        formatter: precise
    root:
      level: INFO
      handlers: [console]
    disable_existing_loggers: false
---
apiVersion: v1
kind: Service
metadata:
  name: rewrite-synapse
  namespace: $namespace
spec:
  selector:
    app.kubernetes.io/name: rewrite-synapse
  ports:
    - name: http
      port: 8008
      targetPort: 8008
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rewrite-synapse
  namespace: $namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: rewrite-synapse
  template:
    metadata:
      labels:
        app.kubernetes.io/name: rewrite-synapse
    spec:
      containers:
        - name: synapse
          image: $synapse_image
          command: ["python", "-m", "synapse.app.homeserver", "--config-path", "/config/homeserver.yaml"]
          ports:
            - containerPort: 8008
          volumeMounts:
            - name: config
              mountPath: /config/homeserver.yaml
              subPath: homeserver.yaml
              readOnly: true
            - name: config
              mountPath: /config/log.config
              subPath: log.config
              readOnly: true
            - name: signing
              mountPath: /config/homeserver.signing.key
              subPath: homeserver.signing.key
              readOnly: true
            - name: media
              mountPath: /media_store
      volumes:
        - name: config
          configMap:
            name: rewrite-synapse-config
        - name: signing
          secret:
            secretName: rewrite-synapse-config
            defaultMode: 0400
        - name: media
          persistentVolumeClaim:
            claimName: rewrite-media
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rewrite-synapse-isolated
  namespace: $namespace
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: rewrite-synapse
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: rewrite-postgres
      ports:
        - protocol: TCP
          port: 5432
EOF
  kubectl_ns rollout status deploy/rewrite-synapse --timeout=240s || true
}

validate() {
  require_bin kubectl
  guard_namespace
  echo "--- pods"
  kubectl_ns get pods -o wide
  echo "--- health"
  kubectl_ns exec deploy/rewrite-synapse -- python - <<'PY' || true
import urllib.request
print(urllib.request.urlopen("http://127.0.0.1:8008/health", timeout=5).read().decode())
PY
  echo
  echo "--- recent logs"
  kubectl_ns logs deploy/rewrite-synapse --tail=120 || true
  echo "--- remaining references in DB"
  kubectl_ns exec deploy/rewrite-postgres -- sh -ceu "export PGPASSWORD='$(postgres_password)'; psql -h 127.0.0.1 -U postgres -d synapse -Atc \"select count(*) from (select 1 from event_json where json::text like '%$old_server%' limit 1) s;\" " || true
  echo "--- media dirs"
  kubectl_ns exec deploy/rewrite-tool -- du -sh /media_store || true
}

delete_scratch() {
  guard_namespace
  kubectl --context="$context" delete namespace "$namespace" --ignore-not-found
}

case "${1:-}" in
  dump-source) dump_source ;;
  inventory-dump) inventory_dump ;;
  scratch-up) scratch_up ;;
  restore-db) restore_db ;;
  rewrite-db) rewrite_db ;;
  repair-owner) repair_db_owner ;;
  copy-media) copy_media ;;
  deploy-synapse) deploy_synapse ;;
  validate) validate ;;
  delete-scratch) delete_scratch ;;
  all-db)
    dump_source
    inventory_dump
    scratch_up
    restore_db
    rewrite_db
    ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; die "unknown command: $1" ;;
esac
