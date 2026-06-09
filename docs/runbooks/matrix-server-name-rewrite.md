# Experimental Matrix server-name rewrite

This runbook is intentionally for disposable clones first. Matrix/Synapse does not support changing `server_name` in-place. The workflow below rewrites database content and media paths enough to test whether an offline clone can boot with a new name.

## Supported use cases

- `m.h4.ddnss.org` -> `matrix-testing.h4xx.io`
- `m.h4.ddnss.org` -> `matrix-staging.h4xx.io`
- `m.h4.ddnss.org` -> `matrix.h4xx.io`

Do not run this against the live `matrix` namespace until the scratch clone has been validated and the expected data loss/federation issues are accepted.

## What the script does

`scripts/matrix-server-name-rewrite.sh`:

1. dumps the source Synapse PostgreSQL database from `docker-host:/mnt/dockerstorage/matrix`;
2. creates an isolated Kubernetes namespace with scratch PostgreSQL and media PVCs;
3. restores the source dump;
4. rewrites `OLD_SERVER` to `NEW_SERVER` in all text/json/jsonb columns;
5. optionally copies `synapsemedia` into the scratch media PVC with a resumable manifest-based copy;
6. deploys a minimal Synapse instance against the rewritten database.

The scratch Synapse deployment is intentionally egress-isolated to PostgreSQL with a `NetworkPolicy`. If the cluster CNI does not enforce NetworkPolicy, keep the scratch service private and do not expose it publicly until federation behavior has been reviewed.

## First test

```sh
cd /home/lukasf/git/lukasfriedhoff/flux-cluster

OLD_SERVER=m.h4.ddnss.org \
NEW_SERVER=matrix-testing.h4xx.io \
NAMESPACE=matrix-rewrite-test \
WORK_DIR=$PWD/.matrix-rewrite/testing \
./scripts/matrix-server-name-rewrite.sh all-db

OLD_SERVER=m.h4.ddnss.org \
NEW_SERVER=matrix-testing.h4xx.io \
NAMESPACE=matrix-rewrite-test \
WORK_DIR=$PWD/.matrix-rewrite/testing \
./scripts/matrix-server-name-rewrite.sh copy-media

OLD_SERVER=m.h4.ddnss.org \
NEW_SERVER=matrix-testing.h4xx.io \
NAMESPACE=matrix-rewrite-test \
WORK_DIR=$PWD/.matrix-rewrite/testing \
./scripts/matrix-server-name-rewrite.sh deploy-synapse

OLD_SERVER=m.h4.ddnss.org \
NEW_SERVER=matrix-testing.h4xx.io \
NAMESPACE=matrix-rewrite-test \
WORK_DIR=$PWD/.matrix-rewrite/testing \
./scripts/matrix-server-name-rewrite.sh validate
```

`copy-media` builds file/size manifests on the source host and scratch PVC, then copies only missing or size-mismatched files in tar batches. It is safe to rerun after an interrupted copy. Tune batch size with `MEDIA_COPY_BATCH_SIZE`, for example:

```sh
MEDIA_COPY_BATCH_SIZE=500 \
OLD_SERVER=m.h4.ddnss.org \
NEW_SERVER=matrix-testing.h4xx.io \
NAMESPACE=matrix-rewrite-test \
WORK_DIR=$PWD/.matrix-rewrite/testing \
./scripts/matrix-server-name-rewrite.sh copy-media
```

## Repeat for another target name

Change only `NEW_SERVER`, `NAMESPACE`, and `WORK_DIR`:

```sh
OLD_SERVER=m.h4.ddnss.org \
NEW_SERVER=matrix-staging.h4xx.io \
NAMESPACE=matrix-rewrite-staging \
WORK_DIR=$PWD/.matrix-rewrite/staging \
./scripts/matrix-server-name-rewrite.sh all-db
```

## Cleanup

```sh
NAMESPACE=matrix-rewrite-test ./scripts/matrix-server-name-rewrite.sh delete-scratch
```

## Expected problems

- Federated room history may fail auth/signature checks because old events were signed under the old homeserver identity.
- Remote servers still know the old MXIDs (`@:m.h4.ddnss.org`), not the rewritten MXIDs.
- Bridges may need separate database/config rewrites before they are useful.
- End-to-end encrypted sessions may not survive cleanly; keep old clients/sessions until testing confirms access.
- This is a clone/rewrite experiment, not an upstream-supported Synapse migration path.

## First observed result

The first `m.h4.ddnss.org` -> `matrix-testing.h4xx.io` scratch run booted Synapse successfully in namespace `matrix-rewrite-test`.

Observed database rewrite counts:

- `users`: 5459 rewritten users with `matrix-testing.h4xx.io`.
- `rooms`: 727 rooms.
- `events`: 478564 events.
- `local_media_repository`: 65691 media records.
- `event_json` old-server references: 0 after rewrite.

Required fixes discovered during the first run:

- Postgres 18 containers must mount the PVC at `/var/lib/postgresql`, not `/var/lib/postgresql/data`.
- Restored objects need ownership repaired to the `synapse` role.
- Scratch Synapse needs `allow_unsafe_locale: true` unless the scratch DB is initialized with locale `C`.
- Scratch Synapse must be egress-isolated; otherwise it attempts federation sends with rewritten identities.
