# Architecture — GEOINT Demo on Azure Local

## Overview

This demo environment runs five integrated GEOINT workloads on a 2-node Azure Local cluster, showcasing VM hosting, Arc-Enabled AKS, edge AI, and Azure IoT Operations. Demo 0 (IoT Backbone) is the foundational sensor ingestion layer that feeds real-time anomaly events into the AI and geospatial workloads.

## End-to-End Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          Azure Local Cluster                                  │
│                    (2× Lenovo SE350, NVIDIA A2 GPU each)                     │
│                                                                               │
│  ┌─────────────────── Demo 0: IoT Backbone ──────────────────────────────┐   │
│  │                                                                        │   │
│  │  ┌──────────────────┐   MQTT (QoS 1)   ┌──────────────────────────┐  │   │
│  │  │ sensor-simulator │ ───────────────► │  AIO MQTT Broker         │  │   │
│  │  │  (K8s Pod)       │  topics:         │  NodePort 31883 (plain)  │  │   │
│  │  │                  │  geoint/sensors/ │  ClusterIP 8883 (TLS)    │  │   │
│  │  │  • weather-stn   │  +/+/telemetry   └──────────┬───────────────┘  │   │
│  │  │  • seismic       │  +/+/alert                  │                  │   │
│  │  │  • rf-detector   │  status (hb)                │ DataFlow         │   │
│  │  └──────────────────┘                    ┌─────────┴─────────────┐   │   │
│  │                                           │ pipeline-sensors      │   │   │
│  │                                           │  → PostGIS ingest API │   │   │
│  │                                           │                       │   │   │
│  │                                           │ pipeline-alerts       │   │   │
│  │                                           │  (filter: alert==true)│   │   │
│  │                                           └─────────┬─────────────┘   │   │
│  │                                                     │ HTTP POST        │   │
│  │                                           ┌─────────▼─────────────┐   │   │
│  │                                           │ alert-processor        │   │   │
│  │                                           │ (FastAPI K8s Pod)      │   │   │
│  │                                           │  POST /trigger         │   │   │
│  │                                           └─────────┬─────────────┘   │   │
│  │  Observability:                                     │                  │   │
│  │  Loki ← Promtail ← pod logs → Grafana              │ HTTP POST        │   │
│  └─────────────────────────────────────────────────────│──────────────────┘   │
│                                                         │                      │
│  ┌─── Node 1 ──────────────────────────────────────────▼────────────────┐    │
│  │  [AKS] Demo 1: AI Vision Pipeline  ◄── triggered by alert-processor  │    │
│  │         YOLOv8 + Foundry Local (GPU: A2)                             │    │
│  │  [VM]   Demo 2: Geospatial Platform                                  │    │
│  │         GeoServer + PostGIS + TileServer GL + MapLibre               │    │
│  └───────────────────────────────────────────────────────────────────────┘    │
│                                                                                │
│  ┌─── Node 2 ─────────────────────────────────────────────────────────────┐   │
│  │  [AKS] Demo 4: Analyst AI Assistant                                    │   │
│  │         Foundry Local SLM + ChromaDB RAG (GPU: A2)                    │   │
│  │  [VM]   Demo 3: 3D Tactical Globe                                      │   │
│  │         CesiumJS + simulated sensor tracks                             │   │
│  └────────────────────────────────────────────────────────────────────────┘   │
│                                                                                │
│  GitOps: Flux ◄── ACR (Azure Container Registry)   Managed via Azure Arc     │
└────────────────────────────────────────────────────────────────────────────────┘
```

## Cluster Topology

### Node 1

| Workload | Type | Resources |
|----------|------|-----------|
| Demo 0: IoT Backbone (sensor-simulator + alert-processor) | AKS Pods | ~2 GB RAM |
| Demo 0: AIO MQTT Broker + DataFlow | AKS (AIO extension) | ~4 GB RAM |
| Demo 1: AI Vision Pipeline | AKS Pod (GPU) | ~16 GB RAM, ~10 GB VRAM |
| Demo 2: Geospatial Platform | VM | ~16 GB RAM |

### Node 2

| Workload | Type | Resources |
|----------|------|-----------|
| Demo 4: Analyst AI Assistant | AKS Pod (GPU) | ~12 GB RAM, ~10 GB VRAM |
| Demo 3: 3D Tactical Globe | VM | ~4 GB RAM |

## Networking

All demos expose HTTP/MQTT services accessible from the booth network:

| Demo | Port(s) | Protocol |
|------|---------|----------|
| Demo 0 — MQTT Broker (NodePort) | 31883 | MQTT (plain, demo) |
| Demo 0 — MQTT Broker (TLS) | 8883 | MQTT/TLS (intra-cluster) |
| Demo 0 — Alert Processor | 8080 | HTTP/REST |
| Demo 1 — Vision Pipeline UI | 8081 | HTTP |
| Demo 1 — Inference API | 8082 | HTTP/REST |
| Demo 2 — MapLibre Viewer | 8083 | HTTP |
| Demo 2 — GeoServer | 8084 | HTTP (OGC WMS/WFS) |
| Demo 3 — CesiumJS Globe | 8085 | HTTP + WebSocket |
| Demo 4 — Chat UI | 8086 | HTTP |

## IoT Backbone — Component Detail (Demo 0)

```
sensor-simulator (K8s Pod)
│   Reads scenario JSON (base / convoy / anomaly)
│   Generates realistic payloads for each sensor type
│   Publishes via paho-mqtt at configurable interval
│
├──► geoint/sensors/{type}/{id}/telemetry   (QoS 1, every 2–5 s)
├──► geoint/sensors/{type}/{id}/alert       (QoS 1, on anomaly)
└──► geoint/sensors/status                  (QoS 0, heartbeat 30 s)
         │
         ▼
AIO MQTT Broker (geoint-broker)
         │
         ├── pipeline-sensors DataFlow
         │     Source : geoint/sensors/+/+/telemetry
         │     Sink   : PostGIS ingest API (Demo 2)
         │
         └── pipeline-alerts DataFlow
               Source : geoint/sensors/+/+/alert
               Filter : alert == true
               Sink   : alert-processor:8080/trigger
                           │
                           ▼
                 alert-processor (FastAPI)
                   • Logs alert to in-memory ring buffer
                   • HTTP POST → demo1-vision-service:8080/jobs
                   • Returns job_id for tracing
```

## Data Flow — Cross-Demo

```
Field Sensors (simulated)
        │ MQTT telemetry
        ▼
Demo 0 (IoT Backbone) ──anomaly alert──► Demo 1 (AI Vision Pipeline)
                                                │ detection results
                        ┌───────────────────────┤
                        ▼                       ▼
               Demo 2 (Map Layers)    Demo 3 (Globe Entities)
                        │                       │
                        └────────┬──────────────┘
                                 ▼
                        Demo 4 (Chat Context)
                        Analyst queries intelligence
```

## GitOps Deployment (AKS Workloads)

```
Azure Container Registry (ACR)
        │
        ▼
   Flux GitOps Controller
        │
        ├── demo0-iot-backbone/
        │     ├── AIO MQTT Broker
        │     ├── sensor-simulator
        │     └── alert-processor
        │
        ├── demo1-vision-pipeline/
        │     ├── Foundry Local (Phi vision model)
        │     ├── YOLOv8 inference service
        │     ├── FastAPI backend
        │     └── React frontend
        │
        └── demo4-ai-assistant/
              ├── Foundry Local (Phi SLM)
              ├── ChromaDB vector store
              ├── RAG pipeline service
              └── Streamlit chat UI
```

## GPU Allocation

Each NVIDIA A2 (16 GB VRAM) is dedicated to one AKS workload:

- **Node 1 A2:** Demo 1 — YOLOv8 (~4 GB) + Foundry Local vision model (~6 GB)
- **Node 2 A2:** Demo 4 — Foundry Local SLM (~6 GB) + ChromaDB embeddings (~2 GB)

GPU passthrough is configured via AKS node pool with `nvidia.com/gpu: 1` resource requests.
