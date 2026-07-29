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
