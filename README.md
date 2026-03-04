# GEOINT Demo — Azure Local Cluster

Geospatial Intelligence (GEOINT) demo workloads running on Azure Local, designed for the **GEOINT 2026 Symposium (USGIF)** and internal Microsoft demonstrations. All workloads run on compact, tactical-class hardware — 2× Lenovo SE350 nodes with NVIDIA A2 GPUs — showcasing edge computing for the defense and intelligence community.

## Demos

| # | Demo | Hosting | Description |
|---|------|---------|-------------|
| 0 | **IoT Backbone** | Arc-Enabled AKS | Simulated field sensors publish MQTT telemetry. Azure IoT Operations ingests, routes, and transforms data at the edge. Anomaly alerts auto-trigger the AI vision pipeline. |
| 1 | **AI Vision Pipeline** | Arc-Enabled AKS | Satellite imagery object detection using YOLOv8 + Foundry Local vision model. Upload imagery, get AI-annotated results with bounding boxes. |
| 2 | **Geospatial Platform** | VM | Full geospatial stack — GeoServer, PostGIS, TileServer GL — with interactive MapLibre GL JS + CesiumJS 3D viewer. |
| 3 | **3D Tactical Globe** | VM | CesiumJS globe with simulated tracks, sensor coverage, and AI-detected objects. Auto-playing kiosk mode. |
| 4 | **Analyst AI Assistant** | Arc-Enabled AKS | Chat-based GEOINT analyst assistant powered by Foundry Local with RAG over intelligence reports. |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Azure Local Cluster                         │
│                (2× Lenovo SE350, A2 GPU each)                   │
│                                                                  │
│  ┌── IoT Layer (Demo 0) ─────────────────────────────────────┐  │
│  │  sensor-simulator ──MQTT──► AIO MQTT Broker               │  │
│  │  (weather / seismic /        └──► DataFlow Pipelines       │  │
│  │   rf-detector)                     └──► alert-processor    │  │
│  └───────────────────────────────────────────────────────────┘  │
│            │ HTTP trigger on anomaly                             │
│            ▼                                                     │
│  ┌─── Node 1 ──────────────────┐  ┌─── Node 2 ──────────────┐  │
│  │  [AKS] AI Vision Pipeline   │  │  [AKS] AI Assistant     │  │
│  │       (GPU: A2)  ◄──────────┘  │       (GPU: A2)         │  │
│  │  [VM]  Geo Platform         │  │  [VM]  CesiumJS Globe   │  │
│  └─────────────────────────────┘  └─────────────────────────┘  │
│                                                                  │
│  GitOps: Flux ←── ACR (Azure Container Registry)                │
│  Managed via Azure Arc                                           │
└─────────────────────────────────────────────────────────────────┘
```

## Hardware Requirements

- **Nodes:** 2× Lenovo SE350 (or equivalent Azure Local validated hardware)
- **GPU:** 1× NVIDIA A2 per node (16 GB VRAM)
- **RAM:** 128 GB per node
- **Connectivity:** Internet-connected (ACR access for Flux GitOps)

## Prerequisites

- Azure Local cluster deployed and registered with Azure Arc
- Arc-Enabled AKS cluster provisioned with GPU passthrough
- Azure Container Registry (ACR) with Flux GitOps configured
- Azure CLI with `az aksarc`, `az stack-hci`, `az connectedk8s`, and `azure-iot-ops` extensions

## Quick Start

```powershell
# 1. Deploy IoT Backbone (Demo 0)
.\demo0-iot-backbone\infra\deploy-iot-backbone.ps1 -EnvFile .env.staging

# 2. Deploy remaining infrastructure (VMs + AKS workloads)
.\scripts\deploy-all.ps1

# 3. Push container images to ACR
.\scripts\setup-acr.ps1

# 4. Load sample geospatial data
.\scripts\seed-data.ps1
```

See [docs/setup-guide.md](docs/setup-guide.md) for detailed instructions.

## Project Structure

```
geoint_demo/
├── demo0-iot-backbone/       # Azure IoT Operations sensor ingestion layer
│   ├── sensor-simulator/     #   MQTT sensor simulator (Python / K8s)
│   ├── event-triggers/       #   Alert processor FastAPI service
│   ├── iot-operations/       #   AIO MQTT broker, assets, pipelines
│   └── infra/                #   Bicep template + deployment script
├── demo1-vision-pipeline/    # AI satellite imagery detection (AKS)
├── demo2-geo-platform/       # GeoServer + PostGIS + MapLibre (VM)
├── demo3-tactical-globe/     # CesiumJS 3D globe (VM)
├── demo4-analyst-assistant/  # Foundry Local chat + RAG (AKS)
├── infra/                    # Bicep templates + Flux GitOps configs
├── scripts/                  # Deployment and data loading scripts
└── docs/                     # Architecture docs + setup guide
```

## Security

See [SECURITY.md](SECURITY.md) for the dependency vulnerability scan results and known design-level security considerations.

## License

See [LICENSE](LICENSE) for details.
