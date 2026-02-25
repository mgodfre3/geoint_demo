# Architecture — GEOINT Demo on Azure Local

## Overview

This demo environment runs four integrated GEOINT workloads on a 2-node Azure Local cluster, showcasing both VM and Arc-Enabled AKS hosting models with edge AI capabilities.

## Cluster Topology

### Node 1

| Workload | Type | Resources |
|----------|------|-----------|
| Demo 1: AI Vision Pipeline | AKS Pod (GPU) | ~16 GB RAM, ~10 GB VRAM |
| Demo 2: Geospatial Platform | VM | ~16 GB RAM |

### Node 2

| Workload | Type | Resources |
|----------|------|-----------|
| Demo 4: Analyst AI Assistant | AKS Pod (GPU) | ~12 GB RAM, ~10 GB VRAM |
| Demo 3: 3D Tactical Globe | VM | ~4 GB RAM |

## Networking

All demos expose HTTP services accessible from the booth network:

| Demo | Port(s) | Protocol |
|------|---------|----------|
| Demo 1 — Vision Pipeline UI | 8081 | HTTP |
| Demo 1 — Inference API | 8082 | HTTP/REST |
| Demo 2 — MapLibre Viewer | 8083 | HTTP |
| Demo 2 — GeoServer | 8084 | HTTP (OGC WMS/WFS) |
| Demo 3 — CesiumJS Globe | 8085 | HTTP + WebSocket |
| Demo 4 — Chat UI | 8086 | HTTP |

## GitOps Deployment (AKS Workloads)

```
Azure Container Registry (ACR)
        │
        ▼
   Flux GitOps Controller
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

## Data Flow

```
Satellite Imagery ──► Demo 1 (AI Detection) ──► Detection Results
                                                      │
                  ┌───────────────────────────────────┤
                  ▼                                   ▼
         Demo 2 (Map Layers)                 Demo 3 (Globe Entities)
                  │                                   │
                  └──────────┬────────────────────────┘
                             ▼
                    Demo 4 (Chat Context)
                    Analyst queries results
```

## GPU Allocation

Each NVIDIA A2 (16 GB VRAM) is dedicated to one AKS workload:

- **Node 1 A2:** Demo 1 — YOLOv8 (~4 GB) + Foundry Local vision model (~6 GB)
- **Node 2 A2:** Demo 4 — Foundry Local SLM (~6 GB) + ChromaDB embeddings (~2 GB)

GPU passthrough is configured via AKS node pool with `nvidia.com/gpu: 1` resource requests.
