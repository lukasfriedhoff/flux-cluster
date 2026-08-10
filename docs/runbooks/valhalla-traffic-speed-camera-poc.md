# Valhalla Traffic and Speed Camera POC

## Goal

Run a testing-only routing proof of concept for OsmAnd+ that demonstrates:

- self-hosted routing based on OpenStreetMap data,
- optional traffic-aware routing if a legal traffic feed is available,
- speed-camera and construction-site overlays for demonstration,
- no dependency on this stack for real driving or safety-critical navigation.

## Constraints

- OsmAnd Android supports custom online routing engines for GraphHopper, OSRM, OpenRouteService, and custom GPX routing. It does not currently list Valhalla as a first-class custom engine.
- Valhalla can route with OpenStreetMap data and supports historical and live traffic, but live traffic must be generated externally as a `traffic.tar` overlay that matches the Valhalla graph tiles.
- Speed-camera warnings are mainly an OsmAnd map/alert feature, not a Valhalla routing feature.
- Blitzer.de data must not be scraped, reverse engineered, or reused unless there is written permission or a documented export/API license. Their public terms forbid reverse engineering and using traffic data without written consent.

## Recommended POC Architecture

### Phase 1: Baseline Routing

- Add a `navigation` or `routing` Flux app on testing.
- Deploy Valhalla with:
  - one persistent tile PVC on SSD storage,
  - one scheduled tile-build Job,
  - one Deployment serving the Valhalla API,
  - one internal service such as `valhalla.navigation.svc.cluster.local:8002`.
- Start with a small extract:
  - preferred: NRW or Germany north/west for fast iteration,
  - avoid full Europe until tile build time and PVC size are measured.
- Expose testing access through VPN-only ingress, not public anonymous internet.

### Phase 2: OsmAnd Integration

- Add a small `valhalla-osmand-gpx-adapter` service.
- Adapter input:
  - OsmAnd custom GPX routing start/end coordinates.
- Adapter behavior:
  - calls Valhalla `/route`,
  - converts the encoded Valhalla route shape to GPX,
  - returns GPX to OsmAnd.
- Keep Valhalla JSON API available separately for debugging with curl and dashboards.
- For phones that are not on VPN, expose only the GPX adapter and protect it with a long random query token stored in SOPS.
  - Do not use Authelia/OIDC for OsmAnd route calculation; OsmAnd's routing client will not complete interactive browser login redirects.
  - Retrieve the testing token from the live cluster when configuring OsmAnd:

    ```bash
    kubectl --context homelab-testing -n navigation get secret valhalla-osmand-token \
      -o jsonpath='{.data.token}' | base64 -d
    ```

  - OsmAnd custom GPX URL template:

    ```text
    https://valhalla-gpx-testing.h4xx.io/route.gpx?token=<TOKEN>&start_lat={start_lat}&start_lon={start_lon}&end_lat={end_lat}&end_lon={end_lon}&costing=auto&language=de-DE
    ```

### Phase 3: Traffic POC

- Historical traffic:
  - only implement if we can obtain legal speed profiles mapped to OSM way IDs,
  - build with `valhalla_ways_to_edges` and `valhalla_add_predicted_traffic`.
- Live traffic:
  - only implement if a legal feed exists,
  - expected inputs are commercial feeds such as HERE/TomTom or public DATEX II-style feeds,
  - generate Valhalla-compatible `TrafficSpeed` tiles and package them as `traffic.tar`.
- If no legal feed is available, keep this phase as a mocked overlay:
  - selected roads get synthetic slowdowns,
  - route comparison proves whether the Valhalla live-traffic mechanism is usable.

### Phase 4: Speed Cameras and Construction Sites

- Use OsmAnd’s existing speed-camera POI/alert support where legally allowed.
- For server-side demo overlays:
  - build a small API that serves GeoJSON/GPX points from legal data sources,
  - start with OpenStreetMap `highway=speed_camera` / enforcement data,
  - add public construction-site feeds where available,
  - add commercial feeds only with a valid license.
- Do not integrate Blitzer.de Plus app traffic/camera data unless written permission or official API/export access exists.

## Minimal Flux Objects

- `apps/navigation/namespace.yaml`
- `apps/navigation/valhalla-tiles-pvc.yaml`
- `apps/navigation/valhalla-config.yaml`
- `apps/navigation/valhalla-tile-build-cronjob.yaml`
- `apps/navigation/valhalla-deployment.yaml`
- `apps/navigation/valhalla-service.yaml`
- `apps/navigation/valhalla-osmand-gpx-adapter.yaml`
- `apps/navigation/valhalla-ingress.yaml`

## Testing Checklist

- Build tiles for the selected extract.
- Query Valhalla `/status` and `/route`.
- Query the adapter with two test coordinates and verify OsmAnd accepts the GPX.
- Compare at least two routes with and without mocked traffic.
- Import speed-camera/construction overlay points into OsmAnd and verify display-only behavior.
- Document tile build duration, PVC usage, memory usage, and route latency.

## Initial Decision

Start with Valhalla plus a GPX adapter on testing. Treat real live traffic and Blitzer.de integration as separate licensing/data-source decisions, not as implementation details.

## References

- Valhalla routing overview: https://valhalla.github.io/valhalla/api/turn-by-turn/overview/
- Valhalla traffic integration: https://valhalla.github.io/valhalla/mjolnir/historical_traffic/
- Valhalla speed priority and live traffic overlay: https://valhalla.github.io/valhalla/speeds/
- OsmAnd online routing: https://osmand.net/docs/user/navigation/routing/online-routing/
- OsmAnd speed camera settings: https://osmand.net/docs/user/personal/global-settings/
- OsmAnd alert widget: https://osmand.net/docs/user/widgets/nav-widgets/
- HERE Safety Cameras API: https://docs.here.com/safety-cameras/docs/introduction
- Blitzer.de terms of use: https://www.blitzer.de/en/terms-of-use/
