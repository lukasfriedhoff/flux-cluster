# Build Cache and Media Promotion

## Build/cache ownership

- Production is the authoritative build stage.
- Testing and staging keep Attic and the remote builder online as fallback capacity, but Hydra is suspended by default to avoid rebuilding the same Nix outputs three times.
- Preferred substituter order is production Attic, then stage-specific caches only for fallback or experiments, then `cache.nixos.org`.
- Preferred remote builder order for clients is production first, staging second, testing third.
- Hydra jobsets should build the `nix` flake once and push completed store paths to the authoritative Attic cache.

## Current stage policy

| Stage | Branch | Hydra | Attic | Remote builder |
| --- | --- | --- | --- | --- |
| testing | `testing` | suspended | enabled | enabled as fallback |
| staging | `develop` | suspended | enabled | enabled as fallback |
| production | `main` | enabled | enabled | enabled first-choice |

## Operational rules

- Do not enable testing or staging Hydra unless validating build-system changes.
- If production Hydra is unhealthy, fix or recover the production cache path first; do not let non-prod Hydra silently become the canonical builder.
- Keep `builders-use-substitutes = true` on clients and builders so remote builders consume existing Attic artifacts before compiling.
- Hydra Nix store PVCs are cache/state for builds, not authoritative artifacts; Attic is the artifact source consumed by clients.
- If a Hydra Nix store PVC gets Longhorn I/O errors, suspend Hydra, recreate only the Nix store PVC, then resume Hydra after Longhorn is healthy.

## Media ownership

- Production media storage is canonical.
- Testing and staging should not redownload the same media from trackers. Use samples, snapshots, or read-only promoted production exports for validation.
- Downloads stay on one canonical downloads filesystem until ARR imports complete, so hardlinks work and imported media does not duplicate data.
- Promotion moves completed, imported torrents from `/downloads` to `/media/staged/<bucket>` after the seed-age policy is met.

## Torrent scaling direction

- Keep qBittorrent’s listening port fixed from Proton NAT-PMP; do not use random ports.
- Split very large torrent sets across multiple qBittorrent instances by purpose (`movies`, `tv`, `music`, `books`, `archive`) instead of one huge client.
- Point Sonarr/Radarr/Lidarr/Readarr at the matching qBittorrent service and keep shared `/downloads` and `/media` mounts where hardlinks are required.
- Add `cross-seed` for finding duplicate seeds from existing data and `qbit_manage` for tagging, no-hardlink detection, orphan cleanup, and ratio/seed lifecycle policy.
- Keep qBittorrent WebUI/API behind Authelia and internal cluster networking; automation talks to the in-cluster service.
