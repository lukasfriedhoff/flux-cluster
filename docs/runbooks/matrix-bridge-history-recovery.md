# Matrix bridge history recovery

Use this runbook when Synapse migration parity is complete but Signal or
WhatsApp conversations are missing messages or media.

## Understand the boundary

Synapse stores Matrix events that bridges already submitted. Copying the
Synapse database or media store again cannot recover messages that the bridge
never imported.

Bridge-native history transfer has additional limits:

- WhatsApp sends history when a linked device is registered. The production
  bridge requests all conversations and up to 1095 days of history, but
  WhatsApp decides what is actually available.
- Signal offers a one-time history transfer while linking the bridge. The
  phone must approve it. Message history can be complete, but attachment
  transfer is normally limited to recent media.
- Standard Synapse cannot insert historical batches into the middle of an
  existing populated room timeline. Mautrix therefore imports initial history
  into newly created portal rooms.
- Mautrix's backward backfill queue is Beeper-specific and must remain disabled
  on this Synapse deployment.

Keep old migrated rooms until replacement portals and their history have been
verified.

## GitOps configuration

Production enables initial history import in:

- `overlays/homelab/secrets/matrix-whatsapp-config.yaml`
- `overlays/homelab/secrets/matrix-signal-config.yaml`

The encrypted bridge configuration requests:

- every initial conversation;
- a WhatsApp full sync with a 1095-day limit;
- up to 100000 initial messages per portal and thread;
- up to 10000 catch-up messages; and
- automatic WhatsApp media requests.

Validate the encrypted configuration before promotion:

```sh
scripts/verify-matrix-bridge-history-import.sh homelab
scripts/verify-matrix-whatsapp-registration.sh homelab
```

Changing these settings does not retroactively trigger a linked-device history
transfer. Relink each bridge after Flux has reconciled the configuration.

## Recover WhatsApp history

1. Take a CNPG backup of `whatsappdb`.
2. Open a direct Matrix room with `@whatsappbot:h4xx.io`.
3. Send `logout`.
4. Send `login qr`.
5. In WhatsApp, open **Linked devices** and scan the QR code.
6. Wait for the history sync to finish before sending portal-management
   commands.
7. Verify a newly created portal contains old messages and recent media.
8. Verify a new inbound and outbound message.

Relinking does not fill gaps inside an existing populated portal. Keep the old
portal as retained history and use the newly created portal when a full import
is required.

## Recover Signal history

1. Take a CNPG backup of `signaldbprivate`.
2. Open a direct Matrix room with `@signalprivatebotUser:h4xx.io`.
3. Send `logout` if the bot reports that the bridge is already linked.
4. Send `login`.
5. In Signal, open **Settings > Linked devices**, add a device, and scan the
   QR code from the bridge bot.
6. Approve the history-transfer prompt on the phone.
7. Keep both devices online until the transfer and portal creation finish.
8. Verify old messages, recent attachments, and a new inbound and outbound
   message.

Do not unlink the old Signal session until the new portal history has been
verified. Signal generally transfers only recent attachments even when older
message bodies are available.

## Verification

After both relinks:

```sh
kubectl -n matrix get pods
kubectl -n matrix logs deploy/whatsapp --since=30m
kubectl -n matrix logs deploy/signalbridgeprivate --since=30m
```

Confirm:

- history sync completed without database or appservice errors;
- new portals use current `h4xx.io` bridge users;
- the current user and bridge bot have the required room power;
- old and new messages are visible; and
- media failures are not caused by missing Megolm keys.

Do not delete old portal rooms or bridge database rows as part of the initial
recovery. Cleanup is a separate, reversible step after parity is documented.
