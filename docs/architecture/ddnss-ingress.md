# ddnss-ingress: the ddnss.org path into the cluster

```
internet -> ionos1 (217.160.11.254, DNAT 80/443 + SNAT to 10.172.0.1)
         -> WireGuard (ionos1 wg0 :61337 <- pod dials OUT, keepalive 25s)
         -> ddnss-ingress pod (10.172.0.4, ns ddnss-ingress)
         -> haproxy (TCP mode, SNI passthrough)
         -> traefik.traefik.svc -> normal ingress routing
```

`ddnss.org` is a dynamic-DNS domain we do not control as a zone — it cannot
be delegated to Cloudflare, so the cloudflared-tunnel pattern used for
h4xx.io does not apply. ionos1 stays the stable public anchor; this tunnel
replaces the legacy leg (ionos1 -> labrouter 10.172.0.3 -> docker-host nginx).

## Why a haproxy container (and not alternatives)

Something in the pod must turn "packets on wg0 for 10.172.0.4:80/443" into
connections to traefik:

- **iptables DNAT in-pod**: DNAT into a ClusterIP from inside a pod fights
  kube-proxy/CNI, is invisible to kubectl, and lives in imperative scripts.
- **WG sidecar on traefik itself**: grafts a tunnel onto the shared ingress
  stack for one legacy domain — wrong blast radius.
- **socat**: process-per-connection, no timeouts/limits/config.

haproxy in TCP mode keeps TLS terminating at traefik (SNI passthrough, so
cert-manager and host rules work unchanged), gives timeouts/maxconn/logs,
and offers an upgrade path: PROXY protocol toward a traefik entrypoint would
restore real client IPs (currently lost to the tunnel SNAT).

## Operational notes

- Pod dials out; no inbound port at home. Keys: cluster private key in SOPS
  (`overlays/homelab/secrets/ddnss-ingress-wg.yaml`), cluster pubkey is a
  peer (`10.172.0.4/32`) in ionos1's `/etc/wireguard/wg0.conf` (Ubuntu box,
  NOT nix-managed).
- The DNAT target on ionos1 decides which backend serves ddnss traffic:
  `10.172.0.3` = legacy labrouter/docker-host, `10.172.0.4` = this tunnel.
  Flip procedure: `docs/runbooks/nextcloud-ddnss-cutover.md`.
- ACME http-01 for ddnss hostnames rides the :80 tunnel path — certs can only
  issue after the DNAT flip.
- Debugging: `wg show wg0 latest-handshakes` on ionos1;
  `curl --resolve <host>:443:10.172.0.4 https://<host>/` from ionos1 tests the
  full path without touching public DNAT.
- Limitation: client IPs appear as 10.172.0.1 (ionos1 SNAT). Acceptable for
  the legacy domain; PROXY protocol is the fix if ever needed.
