# Nextcloud ddnss → homelab cutover (Phase 2)

Goal: nextcloud.h4xx.io serves the merged (ddnss-derived) instance. Prep lives on
the `nextcloud-cutover` branches of flux-apps + flux-cluster. The clone at
nc-clone.h4xx.io validated the whole pipeline (2026-09-19).

**Downtime budget:** ~2 h ddnss freeze; nextcloud.h4xx.io flips near the end.

## Pre-flight (day before)
- [ ] User confirms a window; announce to family/vault users (calendars + passwords live).
- [ ] `nextcloud-cutover` branches reviewed + rebased on main.
- [ ] Clone still healthy (`nc-clone.h4xx.io/status.php`).
- [ ] conv stack present (`conv-mariadb`, `conv-nc` deployments in ns nextcloud) — recreate from session scripts if pruned.

## Cutover
1. **Freeze ddnss** (via nc-migration pod):
   `ssh root@10.0.11.22 'docker exec -u www-data nextcloud-app-1 php occ maintenance:mode --on'`
2. **Final file delta** to the data PVC (same rsync as the clone build; `--size-only`,
   exclude `_repair`). Files land in the SAME user dirs the clone already uses.
3. **Fresh DB conversion** (proven chain):
   dump ddnss mariadb → load into conv-mariadb (Job `nc-load`, bash + `--skip-ssl
   --max-allowed-packet=1G`) → drop/recreate target `nextcloud_merged` on CNPG →
   `occ db:convert-type` (custom_apps mounted, news FK tables emptied first;
   verify 238-ish table count) → upgrade chain 31→32→33→34 via conv-nc image bumps.
4. **Flip prod** (GitOps):
   - merge `nextcloud-cutover` branch of flux-apps (pins/hook/identity plumbing)
   - flux-cluster: add `nextcloud-instance-identity.yaml` to
     `overlays/homelab/secrets/kustomization.yaml` **and** set overlay var
     `nextcloud_postgres_db_name: nextcloud_merged` in the same commit —
     identity and DB must switch together
   - `flux reconcile kustomization secrets` → `nextcloud-app` → HR; pod restarts
     with: merged DB + ddnss identity + NC34-stable apps + smbclient hook
5. **Post-flip occ:** `maintenance:mode --off` (if inherited), `files:scan --all`
   (background), `db:add-missing-indices`.
6. **Smoke:** login as `h4xx` (local) AND via Authelia OIDC; files; CalDAV sync;
   passwords vault decrypts; `/SMB` external mount lists; shares intact.
7. **ddnss stays frozen** (maintenance mode) as read-only-ish fallback for the
   grace period. Do NOT unfreeze for writes — split-brain.

## Rollback (any point before step 6 passes)
Revert the flux-cluster cutover commit (identity secret out of kustomization +
db name back) → reconcile. Old prod DB (`nextcloud`) is untouched throughout.

## ddnss.org path flip (same window, after step 6 passes)
The k8s WireGuard leg is LIVE and tested (ionos1 -> wg -> ddnss-ingress pod
10.172.0.4 -> haproxy -> traefik; :80=301, :443 SNI routes correctly).
On ionos1 (Ubuntu, NOT nix-managed):
- [ ] Replace the PREROUTING DNAT targets for 80/443: 10.172.0.3 -> 10.172.0.4;
      add matching SNAT POSTROUTING rules
      (`-d 10.172.0.4 --dport 80/443 -j SNAT --to-source 10.172.0.1`);
      drop the port 8008 rule (dead matrix legacy). Persist the rules.
- [ ] Add the ddnss hosts to the nextcloud ingress (nextcloud.h4.ddnss.org,
      h4.ddnss.org) + 301 redirects for retired names (oodocs, gua,
      cloud.h4xx.io -> nextcloud.h4xx.io). Certs via http-01 over the tunnel.
- [ ] Office: Collabora only (decision 2026-09-19); onlyoffice and
      oodocs.h4.ddnss.org are NOT migrated.
- [ ] Retire the labrouter WG peer (10.172.0.3) + its forwards when the
      docker-host is decommissioned.

## Post-cutover cleanup
- Repoint ddnss clients (mobile apps, CalDAV/CardDAV accounts) to nextcloud.h4xx.io.
- Delete: nextcloud-clone deploy/svc/ingress, conv-* stack, nc-migration pod,
  migration SSH pubkey on ddnss, PVC dirs `_migrate/` + `.clone/`, `nextcloud_clone` DB.
- Renovate PRs #44–#50: superseded by the branch pins — close or rebase.
- Docker-host follow-ups: onlyoffice/elasticsearch equivalents (fulltextsearch
  skipped in the merge), scanserver-samba stays (SMB mounts point at it).

## Traps (from the clone build)
- `occ upgrade` refuses without a `version` key in config.php.
- Upgrades DISABLE third-party apps; the pinned seed re-installs, but `app:enable`
  needs NC34-compatible versions (hence the branch pin bump).
- Instance identity (secret/passwordsalt/instanceid) must match the DB or logins
  + vault break silently.
- helm-controller `valuesFrom targetPath` cannot carry JSON (strvals) — use
  values-fragment secrets.
