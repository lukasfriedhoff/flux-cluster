# Experimental Matrix server-name rewrite

This runbook is intentionally for disposable clones first. Matrix/Synapse does not support changing `server_name` in-place. The workflow below rewrites database content and media paths enough to test whether an offline clone can boot with a new name.

## Supported use cases

- `m.h4.ddnss.org` -> `matrix-testing.h4xx.io`
- `m.h4.ddnss.org` -> `matrix-staging.h4xx.io`
- `m.h4.ddnss.org` -> `h4xx.io`

Do not run this against the live `matrix` namespace until the scratch clone has been validated and the expected data loss/federation issues are accepted.

## What the script does

`scripts/matrix-server-name-rewrite.sh`:

1. dumps the source Synapse PostgreSQL database from `docker-host:/mnt/dockerstorage/matrix`;
2. creates an isolated Kubernetes namespace with scratch PostgreSQL and media PVCs;
3. restores the source dump;
4. rewrites mutable `OLD_SERVER` references to `NEW_SERVER` while preserving `public.event_json.json`;
5. optionally copies `synapsemedia` into the scratch media PVC with a resumable manifest-based copy;
6. deploys a minimal Synapse instance against the rewritten database.

Do not rewrite the plain SQL restore stream. Matrix event IDs are content-addressed
from signed event payloads in `public.event_json.json`. Changing those payloads
without recomputing and resigning the complete event graph causes
`DatabaseCorruptionError` during authenticated `/sync`. The
`restore-db-rewritten` and `all-db-stream` commands are intentionally disabled.

The scratch Synapse deployment is intentionally egress-isolated to PostgreSQL
and cluster DNS with a `NetworkPolicy`. If the cluster CNI does not enforce
NetworkPolicy, keep the scratch service private and do not expose it publicly
until federation behavior has been reviewed.

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

Create a disposable scratch user and pass its access token during final
validation. A health check alone does not exercise event loading:

```sh
MATRIX_TEST_ACCESS_TOKEN='<scratch access token>' \
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

Production-name scratch test:

```sh
OLD_SERVER=m.h4.ddnss.org \
NEW_SERVER=h4xx.io \
NAMESPACE=matrix-rewrite-prod-dryrun \
WORK_DIR=$PWD/.matrix-rewrite/prod-h4xx \
KUBECONTEXT=homelab-prod \
STORAGE_CLASS=longhorn-ssd-rwo-2r \
POSTGRES_SIZE=12Gi \
MEDIA_SIZE=60Gi \
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
- Old server-name references in signed `event_json` payloads are expected and
  must not be treated as failed rewrite residue.

## Repair retained room administrators

Retained rooms preserve their signed room IDs and power-level state. The
current-domain user and bridge bot therefore do not automatically inherit the
old-domain identities' room power.

Use the supported Synapse admin endpoint through
`scripts/repair-matrix-migrated-room-admins.sh`:

```sh
TARGET_USER_ID='@lukasf:h4xx.io' \
ACCESS_TOKEN_FILE=/run/secrets/synapse-admin-token \
SYNAPSE_URL=http://127.0.0.1:8008 \
  scripts/repair-matrix-migrated-room-admins.sh repair retained-room-ids.txt
```

Run the same command for a current bridge bot only after a joined
current-domain room administrator exists. The command is intentionally unable
to repair a room whose only administrators use the old server name. Replacing
such a bridge portal is safer than directly changing Synapse event tables,
because Matrix room state is signed and event-linked.

The script inventories power levels through Synapse's admin room-state API,
not the client room-state API. This is required because a server administrator
does not have to be joined to every retained room.

Validate changes to the repair tool with:

```sh
scripts/verify-matrix-migrated-room-admin-repair.sh
```

## Expose retained room history to the current user

Joining the current-domain user to a retained room does not expose events that
predate that membership when the room uses `joined` history visibility.
Clients show those events as unavailable even though Synapse retained them.

After granting the current-domain user room administrator power, use a
short-lived Synapse server administrator to emit a signed
`m.room.history_visibility` state event:

```sh
REPAIR_USER_ID='@migration-repair:h4xx.io' \
ACCESS_TOKEN_FILE=/run/secrets/temporary-synapse-admin-token \
SYNAPSE_URL=http://127.0.0.1:8008 \
  scripts/repair-matrix-migrated-history-visibility.sh repair retained-room-ids.txt
```

The repair defaults to `shared`, which keeps the room private while allowing
joined members to read the retained history. The temporary repair account is
made room administrator through Synapse's supported API, explicitly joins the
room, writes the state event through the Matrix client API, verifies it, and
leaves each room. The explicit join avoids a race where Synapse has accepted
the admin request but the client state endpoint still reports that the repair
user is not in the room. Delete or deactivate that account after the repair.

This only repairs Matrix history visibility. It cannot decrypt end-to-end
encrypted events for a new account. If an old room displays `You don't have
access to this message` after the room-state repair, restore the old account's
Megolm keys instead:

1. Open a surviving client session for the old account.
2. Unlock its key backup with the old recovery key or passphrase.
3. Export the room keys from that client.
4. Import the room keys into the current account.

The server stores encrypted event payloads and public device metadata, but it
does not possess the private recovery key needed to decrypt or re-encrypt old
Megolm sessions. Without a surviving client crypto store or recovery key, the
old encrypted message bodies cannot be recovered server-side.

Validate changes to the repair tool with:

```sh
scripts/verify-matrix-migrated-history-visibility.sh
```

## Expose retained-origin media

Signed events retain their original `mxc://<old-server>/...` URLs. Copying the
old media store into the new Synapse local-media directory is not sufficient:
Synapse correctly treats those URLs as remote media after the server-name
change.

Run `repair-matrix-migrated-media-cache.py` inside the new Synapse container
after taking a database backup:

```sh
python /tmp/repair-matrix-migrated-media-cache.py \
  --origin m.h4.ddnss.org

python /tmp/repair-matrix-migrated-media-cache.py \
  --origin m.h4.ddnss.org \
  --apply
```

The tool:

- discovers retained-origin MXC IDs directly from signed event JSON without
  modifying those events;
- requires every referenced ID to exist in `local_media_repository`;
- hardlinks local media and thumbnails into Synapse's remote-cache layout, so
  the migration does not duplicate their disk usage;
- upserts the matching `remote_media_cache` metadata transactionally; and
- is idempotent, allowing interrupted runs to be repeated safely.

Validate filesystem behavior with:

```sh
scripts/verify-matrix-migrated-media-cache.py
```

The media-cache repair only makes the retained encrypted bytes reachable under
their original MXC origin. A broken encrypted image after this repair usually
means the client lacks the corresponding Megolm room key; it does not imply
that the media object is missing.

## Verify source parity before another sync

Compare immutable Synapse event IDs and media IDs between source and target
before copying data again. If the target already contains every source event
and media ID, another database or media sync cannot restore inaccessible
encrypted content and only increases migration risk.

Bridge databases should be checked separately:

- portal and message mappings prove whether the bridge history was imported;
- empty backfill/history-sync queues mean there is no pending bridge history;
- relinking a Signal or WhatsApp account repairs future traffic but does not
  reconstruct ciphertext that the remote service no longer offers; and
- `signalmeow_event_buffer` rows with a null `plaintext` column are processed
  deduplication markers, not pending messages. Do not replay them as chat
  content.

If source event parity is complete but a bridge never imported remote history,
use `docs/runbooks/matrix-bridge-history-recovery.md`. Do not repeat the
Synapse database migration.

## First observed result

The first `m.h4.ddnss.org` -> `matrix-testing.h4xx.io` scratch run booted Synapse successfully in namespace `matrix-rewrite-test`.

Observed database rewrite counts:

- `users`: 5459 rewritten users with `matrix-testing.h4xx.io`.
- `rooms`: 727 rooms.
- `events`: 478564 events.
- `local_media_repository`: 65691 media records.
- `event_json` payloads retain the original signed JSON so stored event IDs keep
  matching their content hashes.

Required fixes discovered during the first run:

- Postgres 18 containers must mount the PVC at `/var/lib/postgresql`, not `/var/lib/postgresql/data`.
- Restored objects need ownership repaired to the `synapse` role.
- Scratch Synapse needs `allow_unsafe_locale: true` unless the scratch DB is initialized with locale `C`.
- Scratch Synapse must be egress-isolated; otherwise it attempts federation sends with rewritten identities.

## Production repair lesson

The initial production rewrite used a stream-wide `sed` replacement. Synapse
booted and passed `/health`, but authenticated `/sync` failed because signed
event JSON no longer matched stored event IDs. The repair restored original
event payloads from the source dump while retaining rewritten indexed
identifiers. Always take a fresh CNPG backup before a repair and require an
authenticated `/sync` result with a non-zero joined-room count before accepting
a rewrite.
