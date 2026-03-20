# GEOINT Demo — Full Scenario Guide

This document ties together the four demos (IoT backbone + Vision + Geo Platform + Tactical Globe + Analyst Assistant) into one narrative that mirrors the "seismic spike followed by convoy" storyline we have been rehearsing.

## 1. Storyline & Objectives

1. **Detection:** Edge sensors (weather, seismic, RF) flag abnormal readings near a logistics yard.
2. **Verification:** Task the AI vision pipeline with last-pass satellite imagery to confirm vehicle movement.
3. **Contextualize:** Push detections into the geospatial platform and globe to share a common operating picture.
4. **Assess:** Use the analyst assistant to ask follow-up questions that blend new detections with historical reporting.

Key takeaway: everything runs on two rugged Azure Local nodes—no cloud round trips once deployed.

## 2. Environment Quick Reference

| Component | Role | IP / Location | Ports | Suggested DNS A record (optional) |
|-----------|------|---------------|-------|----------------------------------|
| AKS worker node | Hosts Demo 1 & Demo 4 pods, IoT Operations extension | `172.22.84.50` | 8081 (Vision UI), 8082 (Vision API), 8086 (Analyst UI), NodePort `31883` (MQTT) | `aks.den.geoint.local` |
| VM: Geo Platform | Demo 2 containers (GeoServer, PostGIS, TileServer, ingest UI) | `172.22.84.42` | 8083 (MapLibre/Cesium UI), 8084 (GeoServer), 8085 (TileServer internal) | `geo.den.geoint.local` |
| VM: Tactical Globe | Demo 3 Cesium kiosk | `172.22.84.43` | 8085 (Globe UI) | `globe.den.geoint.local` |
| Sensor Simulator (optional laptop) | Publishes MQTT telemetry | operator workstation | — | `sim.den.geoint.local` (CNAME to laptop) |

> Update `.env.denver` if IPs change so helper scripts stay consistent. DNS names should resolve on the booth LAN only; no public DNS needed.

## 3. System Architecture

```mermaid
graph LR
    subgraph Edge Sensors & Simulators
        S1[Seismic arrays]
        S2[RF detectors]
        S3[Weather stations]
        SIM[Python sensor-simulator]
    end

    subgraph Azure Local Node 1
        AKS[Arc-Enabled AKS\n(NVIDIA A2)]
        MQTT[(IoT Operations MQTT broker\nNodePort 31883)]
        Vision[Demo1 Vision Pipeline\nYOLOv8 + Foundry Local]
        Analyst[Demo4 Analyst Assistant\nFoundry Local SLM + RAG]
    end

    subgraph Azure Local Node 1 VM (Geo Platform)
        Ingest[postgis-ingest]
        PostGIS[(PostGIS 16)]
        GeoServer[GeoServer 2.25]
        MapUI[MapLibre/Cesium UI :8083]
    end

    subgraph Azure Local Node 2 VM (Globe)
        Globe[Demo3 Cesium Globe :8085]
    end

    S1 & S2 & S3 & SIM -->|MQTT telemetry| MQTT --> Ingest
    Vision -->|Detection GeoJSON| PostGIS
    Ingest --> PostGIS --> GeoServer --> MapUI
    PostGIS --> Globe
    Vision --> Analyst
    GeoServer --> Analyst
    Globe --> Analyst
```

## 4. Data Flow (What & Why)

1. **Sensors → MQTT (Demo0):** `sensor-simulator` (or real devices) publishes to `geoint/sensors/...` topics. We highlight contested connectivity by showing the simulator connected through the node-port-forward.
2. **MQTT → PostGIS:** `postgis-ingest` subscribes to `geoint/pipelines/sensor-telemetry`, adds geospatial metadata, and persists features. This proves we can ingest multi-INT data without cloud services.
3. **Vision Tasking (Demo1):** When seismic spikes imply vehicle activity, we upload the latest satellite strip. YOLOv8 + Foundry Local vision model run on the node GPU, producing detections in seconds.
4. **Dissemination (Demo2 + Demo3):** New detections hit PostGIS and are immediately exposed via GeoServer and TileServer GL. The MapLibre 2D UI and Cesium 3D globe both refresh automatically, giving command staff an updated COP.
5. **Analyst Reasoning (Demo4):** The analyst asks the assistant for context ("Any prior hostile logistics at this grid?"). The assistant fuses the just-ingested detections with its local RAG corpus and citations, keeping sensitive data on-prem.

## 5. Demo Choreography (15-minute show)

1. **Warm-up checks (backstage):**
   - Confirm DNS resolves (e.g., `nslookup mqtt.den.geoint.local`).
   - `systemctl status demo2-geoplatform`, `demo3-globe`, and `sensor-simulator` should show `active (exited|running)`; if not, `sudo systemctl restart <service>`.
   - `kubectl get pods -n demo1,demo4` to verify the vision + analyst deployments are `Running` (Flux keeps them alive).
   - Browse to `http://geo.den.geoint.local:8080` (landing page) and ensure all tiles show green before inviting customers.

2. **Kick off sensor scenario (Minute 0):**
   - Sensor simulator now runs as a systemd service. If you want to reset the storyline, `sudo systemctl restart sensor-simulator` on the host.
   - Tail logs with `journalctl -fu sensor-simulator` to narrate seismic alerts and truck RF signatures.

3. **Vision tasking (Minute 3):**
   - In browser go to `http://172.22.84.50:8081` (or `vision.den.geoint.local`).
   - Upload the latest image from `demo1-vision-pipeline/frontend/public/samples/convoy.png`.
   - Call out the YOLO detections (trucks, fuelers) and latency (<5s).

4. **Geospatial platform (Minute 5):**
   - Switch to `http://172.22.84.42:8083`.
   - Toggle layers: `Seismic Alerts`, `Vehicle Detections`, `Weather`. Click a point to show attributes (confidence, timestamp, sensor ID).
   - Mention GeoServer endpoints accessible at `http://172.22.84.42:8084/geoserver/web/` for coalition sharing.

5. **3D Tactical Globe (Minute 8):**
   - On kiosk screen open `http://172.22.84.43:8085`. Let the autoplay sequence show convoy tracks. Pause to fly camera and demonstrate sensor coverage volumes.

6. **Analyst assistant (Minute 11):**
   - Go to `http://172.22.84.50:8086`.
   - Ask: *"Summarize seismic activity near GRID 57S between 0900-1200Z and correlate with vehicle detections."*
   - Follow-up: *"What historical reporting references that logistics yard?"* Emphasize on-device LLM + citations from the local corpus.

7. **Close (Minute 14):**
   - Recap: "Sensors to shooters in one kit—data never leaves the TOC, and every component uses open standards governed through Arc."

## 6. DNS & Access Planning

If you can control the event LAN DNS, create the following A records pointing at the IPs above to simplify demo narration:

| Hostname | IP | Purpose |
|----------|----|---------|
| `vision.den.geoint.local` | 172.22.84.50 | Demo 1 UI / API |
| `geo.den.geoint.local` | 172.22.84.42 | Demo 2 Map UI + GeoServer |
| `globe.den.geoint.local` | 172.22.84.43 | Demo 3 Globe |
| `analyst.den.geoint.local` | 172.22.84.50 | Demo 4 UI |
| `mqtt.den.geoint.local` | 172.22.84.50 | NodePort 31883 for simulators |

Use split-horizon DNS (e.g., Windows DNS on the booth switch) or add host entries on presenter laptops. Ensure firewall rules allow TCP 8081–8086 and 31883 intra-LAN.

## 7. Common Questions & Answers

| Question | Answer |
|----------|--------|
| "How do the demos hand data off?" | Sensor telemetry and vision detections are normalized into PostGIS. GeoServer/TileServer expose those features for Demo 2 & 3, while Demo 4 reads both PostGIS and its report corpus for RAG context. |
| "What if the WAN drops?" | All AI models, databases, and message brokers run on-prem. Arc connectivity resumes automatically, but the mission workflows continue offline. |
| "Can we ingest our own sensor formats?" | Update `demo0` simulator or field gateway to publish to the same MQTT topics; `postgis-ingest` is Python with JSON schemas that can be extended quickly. |
| "How do we multi-classify outputs?" | Each detection carries metadata tags (sensor, confidence, timestamp) stored in PostGIS; GeoServer can enforce per-layer access if you integrate with Arc/Entra ID. |
| "Is there a single pane of glass?" | The map UI already embeds a Cesium tab, and Flux/Arc dashboards provide health status. Additional orchestrations can overlay Demo 1 thumbnails or Demo 4 summaries via existing APIs. |

## 8. References

- Sensor simulator usage: `demo0-iot-backbone/sensor-simulator/simulator.py`
- Compose env: `demo2-geo-platform/.env`
- Event operations: [docs/event-runbook.md](event-runbook.md)
- Demo-specific deep dive: [docs/demo2-geo-platform-demo-guide.md](demo2-geo-platform-demo-guide.md)
- Automation details: [docs/automation-playbook.md](automation-playbook.md)
