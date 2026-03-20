# Demo 2 — Geospatial Platform Field Guide

This guide captures the story line, architecture, runbook, and talking points for showcasing the GeoServer/PostGIS stack that runs on the Demo 2 VM. Use it as both a rehearsal checklist and a customer-facing script.

## 1. Narrative and Goals

- **What:** Edge-hosted Open Geospatial Consortium (OGC) stack combining GeoServer, PostGIS, TileServer GL, and a MapLibre + Cesium front end.
- **Why it matters:** Demonstrates that modern GEOINT infrastructure (data ingest, storage, visualization) fits on suitcase-grade hardware with zero cloud dependency once deployed.
- **Audience outcomes:** Understand rapid ingestion of sensor detections, standards-based data services, and how the map can federate with other mission systems through WMS/WFS.

## 2. Architecture at a Glance

```mermaid
graph LR
    subgraph Azure Local Node 1 VM
        broker[IoT Operations MQTT broker\n(NodePort 31883)] --> ingest[postgis-ingest worker\n(Python, MQTT→PostGIS)]
        ingest --> postgis[(PostGIS 16\nvector + raster store)]
        postgis --> geoserver[GeoServer 2.25\nOGC services]
        postgis --> tileserver[TileServer GL\nvector tiles]
        geoserver --> mapviewer[MapLibre + Cesium UI\n(port 8083)]
        tileserver --> mapviewer
    end
```

**Data path:** MQTT telemetry (sensor detections) → `postgis-ingest` parses payloads → inserts into PostGIS tables → GeoServer + TileServer expose layers → MapLibre renders layers and Cesium visualizes 3D overlays.

## 3. Environment Checklist

| Item | Command / Notes |
|------|-----------------|
| Port-forward IoT broker | `kubectl port-forward -n azure-iot-operations service/aio-broker-nodeport 31883:1883` (keep running while ingesting) |
| Compose env file | `demo2-geo-platform/.env` already sets `MQTT_HOST`, `MQTT_PORT`, `MQTT_USERNAME`, `MQTT_PASSWORD`, `MQTT_TOPIC` |
| Start stack | `cd demo2-geo-platform && docker compose up -d` |
| Health check | `docker compose ps`, `docker compose logs postgis-ingest --tail=20` |
| UI URL | `http://<vm-geoserver-ip>:8083` (primary viewer) |

## 4. Demo Flow (10 minutes)

1. **Set the scene (1 min):** "This single node hosts our geospatial data plane—standard OGC services, PostGIS analytics, and a Cesium/MapLibre UI." Mention ruggedized hardware and Azure Arc manageability.
2. **Show real-time ingest (2 min):** Keep `docker compose logs postgis-ingest` running and point to live inserts when scenario playback is running. Highlight MQTT-based integration with the IoT backbone.
3. **Map interaction (4 min):**
   - Pan/zoom MapLibre UI, switch between base maps.
   - Toggle detection layers (vehicles, RF, weather) to show multi-int collection.
   - Click a feature → discuss attributes (confidence, timestamp, sensor id).
4. **3D context (2 min):** Switch to Cesium panel (tab inside UI) to show the same detections in 3D with terrain drape.
5. **Wrap with interoperability (1 min):** Show GeoServer capabilities page (`http://<vm-ip>:8084/geoserver/web/`) to prove WMS/WFS endpoints exist for coalition sharing.

## 5. Talking Points & Relevance

- **Edge persistence:** PostGIS + GeoServer run fully disconnected; once data is in, analysts do not rely on WAN links.
- **Rapid fusion:** MQTT pipeline lets any sensor publish detections; ingest container normalizes payloads into schema-managed tables.
- **Standards-first:** OGC APIs (WMS/WFS/WCS) so existing tools (ArcGIS, QGIS) can subscribe instantly.
- **Open tooling:** MapLibre, Cesium, TileServer GL, PostGIS—all OSS, minimizing licensing friction for coalition deployments.
- **Arc integration:** VM can still be governed through Azure Arc for insights, policy, and lifecycle management even though workloads stay local.

## 6. FAQ & Sound Bites

| Question | Recommended Answer |
|----------|--------------------|
| "Does this need the public cloud after setup?" | No. After the initial container image sync via ACR, everything—including data ingest, storage, rendering, and analytics—runs locally. |
| "How do I connect my existing GIS tools?" | Use the GeoServer WMS/WFS endpoints (`http://<vm-ip>:8084/geoserver/...`). The same layers shown in the demo can be consumed by ArcGIS Pro, QGIS, or any OGC-compliant client. |
| "What feeds the detections?" | The IoT Operations backbone publishes MQTT messages (vehicles, RF, weather). `postgis-ingest` subscribes to `geoint/pipelines/sensor-telemetry`, validates payloads, and writes to PostGIS. |
| "Can we swap in our own sensor schema?" | Yes—update the ingestion script and PostGIS schema; GeoServer automatically exposes new layers once published. |
| "How resilient is the stack?" | Containers restart automatically via Docker Compose; PostGIS data lives on persistent storage. Loss of internet has no impact on operations. |

## 7. Troubleshooting Quick Hits

- `postgis-ingest` offline → ensure the broker port-forward is active or update `.env` with actual AKS worker IP reachable from the VM.
- Map shows no tiles → `docker compose logs tileserver --tail=50` and confirm `/tileserver/styles` data exists.
- GeoServer auth prompt → default admin credentials `admin/geoserver` (change before customer-facing use).
- Slow queries → verify PostGIS container has adequate CPU (8 vCPU recommended) and vacuum tables if event volume is very high.

## 8. Why This Demo Resonates

- Addresses **contested connectivity**: everything runs on-site.
- Highlights **open standards interoperability** without proprietary lock-in.
- Demonstrates **rapid task force deployment**—two rugged nodes deliver a full GEOINT enterprise stack.
- Bridges **sensor-to-analyst latency**: detections go from MQTT to map in under a second, showing tactical decision advantage.
