# Mautrix WhatsApp session recovery

Use this runbook when the WhatsApp bridge is connected but repeatedly reports
`failed to decrypt normal message` or a Signal message index far in the future.

## Diagnosis

1. Confirm Synapse and the WhatsApp bridge are healthy.
2. Check whether failures are limited to one sender or portal.
3. Back up the bridge database before changing any WhatsApp session rows.
4. Compare the affected `whatsmeow_sessions` row with the source database when
   the failure follows a migration.

Do not delete the complete bridge database. Existing Matrix room history,
portal mappings, and bridge message mappings are independent from a single
broken WhatsApp Signal ratchet.

## Recovery

The supported recovery for a linked-device Signal session that cannot
re-establish itself is to relink WhatsApp:

1. Open a direct Matrix room with `@whatsappbot:<server-name>`.
2. Send `logout`.
3. Send `login qr`.
4. Scan the QR code in WhatsApp under **Linked devices**.
5. Wait for the bridge to reconnect and complete its history sync.
6. Send a new WhatsApp message and verify that no new undecryptable-message
   notices are created.

Old undecryptable notice events cannot generally be converted back into
plaintext unless WhatsApp re-sends the original encrypted payload. Relinking
repairs future traffic and starts a new supported history sync.

## GitOps safeguards

- Pin the bridge image by digest rather than using a moving `latest` image.
- Keep `network.use_whatsapp_retry_store` enabled so outgoing messages remain
  available for retry receipts across bridge restarts.
- Preserve the bridge database and app data PVC during rollouts.
- Allow both phone-number and LID bridge users in the Synapse appservice
  registration:

  ```regex
  ^@whatsapp_(?:[0-9]+|lid-[0-9]+):<server-name>$
  ```

  Recent WhatsApp linked devices can identify contacts with `lid-*` user IDs.
  If the appservice only accepts phone numbers, Synapse rejects those users
  with `M_EXCLUSIVE` and portal synchronization remains incomplete.
- Run `scripts/verify-matrix-whatsapp-registration.sh` before promoting Matrix
  secret changes.

## Migrated rooms

Rooms retained from a server-name migration keep their original room IDs and
state history. Relinking the current bridge does not automatically grant the
new `@whatsappbot:<server-name>` user permission to repair those rooms.

Before resynchronizing migrated portals:

1. Back up the bridge and Synapse databases.
2. Ensure the current bridge bot is joined to each retained portal room.
3. Grant it enough power to update bridge state and invite current ghost users.
4. Keep the current human owner joined with administrator power.
5. Resynchronize the portal and confirm that no new `M_FORBIDDEN` or
   `M_EXCLUSIVE` errors are emitted.

Do not remove old ghost users until new messages and membership updates work.

### Supported room-admin repair

Use `scripts/repair-matrix-whatsapp-migrated-rooms.sh` to inventory retained
rooms and grant the current bridge bot administrator power where a current
local administrator already exists:

```sh
ACCESS_TOKEN_FILE=/run/secrets/synapse-admin-token \
  SYNAPSE_URL=http://127.0.0.1:8008 \
  scripts/repair-matrix-whatsapp-migrated-rooms.sh inventory room-ids.txt

ACCESS_TOKEN_FILE=/run/secrets/synapse-admin-token \
  SYNAPSE_URL=http://127.0.0.1:8008 \
  scripts/repair-matrix-whatsapp-migrated-rooms.sh repair room-ids.txt
```

The repair command:

- uses Synapse's supported `make_room_admin` API;
- skips rooms that are already repaired;
- skips rooms without a current local administrator;
- observes Synapse rate limits and retries with the advertised delay;
- verifies the bridge bot's resulting room power; and
- never prints the access token.

Run `scripts/verify-matrix-whatsapp-room-repair.sh` after changing the tool.

### Rooms without a current local administrator

Synapse cannot impersonate an old-server-name user, and
`make_room_admin` cannot recover a room that has no current local
administrator. Do not repair these rooms by directly editing Synapse event or
state tables: room state is signed, event-linked data and direct SQL updates
can create state that clients or federation cannot validate.

For those rooms, retain the old room as read-only history and create a new
portal room with the current bridge identity. Prove this workflow on one room
before processing the rest:

1. Record and back up the old portal mapping.
2. Create a new portal for the same remote chat using the bridge's supported
   portal command or provisioning API.
3. Confirm the current user joins and the current bridge bot has administrator
   power.
4. Trigger history synchronization/backfill and verify new inbound and outbound
   messages.
5. Keep the old room and mapping until the replacement has been validated.

Relinking restores future WhatsApp traffic. Historical
`failed to decrypt normal message` notices cannot be recovered unless WhatsApp
re-sends the original encrypted payload.

Before attempting another migration sync, compare the source and target bridge
message mappings and inspect the history-sync/backfill queues. If every source
mapping exists on the target and the queues are empty, the bridge has no
additional historical payload to import. Missing plaintext in that case is a
remote Signal-ratchet limitation rather than an incomplete database copy.
