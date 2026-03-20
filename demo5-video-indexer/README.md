# Demo 5 — Video Indexer: Tactical Edge Situational Awareness

Real-time video intelligence at the edge using **Azure AI Video Indexer enabled by Arc**. A single NVIDIA A2 GPU processes a live RTSP camera feed, detecting persons, objects, and custom-defined threats — fully disconnected, no cloud required.

## What It Does

| Feature | Description |
|---------|-------------|
| **Live AI Overlays** | Real-time bounding boxes and tracking IDs on persons/objects |
| **Perimeter Monitoring** | Area-of-interest zones with entry/exit counting |
| **Custom Threat Detection** | Natural-language defined detections (e.g., "unattended bag") |
| **Recording & Replay** | All footage + insights stored locally for review |
| **Zero Cloud Dependency** | Runs entirely on the Mobile Cluster's A2 GPU |

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│              Mobile Cluster (Azure Local)                 │
│                                                          │
│  ┌──────────┐  RTSP   ┌──────────────────────────────┐  │
│  │ IP Camera│────────▶│  Video Indexer Arc Extension  │  │
│  │ (1080p)  │         │  ┌──────────┐ ┌───────────┐  │  │
│  └──────────┘         │  │DeepStream│ │ Custom AI  │  │  │
│                       │  │(A2 GPU)  │ │ Insights   │  │  │
│                       │  └──────────┘ └───────────┘  │  │
│                       │  ┌──────────┐ ┌───────────┐  │  │
│                       │  │ Overlay  │ │ Recording  │  │  │
│                       │  │ Engine   │ │ Storage    │  │  │
│                       │  └──────────┘ └───────────┘  │  │
│                       └──────────────────────────────┘  │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │  Laptop / Tablet (Browser)                         │  │
│  │  VI Web Portal → Live Feed + Bounding Boxes + AOI  │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

## Hardware Requirements

| Component | Spec |
|-----------|------|
| GPU Node | 16 cores, 64 GB RAM, 200 GB storage, NVIDIA A2 |
| CPU Node | 32 cores, 64 GB RAM, 200 GB storage |
| Camera | Static PoE IP camera, RTSP, 30 FPS, ≥1080p |
| Storage | RWX storage class (Longhorn), 50 GB/camera/day |

## Prerequisites

1. **Azure subscription approved** for VI real-time analysis — [Register here](https://aka.ms/vi-live-register)
2. **Azure AI Video Indexer account** created in Azure Portal
3. **Arc-enabled AKS cluster** with GPU node and NVIDIA GPU Operator installed
4. **RWX storage class** (Longhorn or equivalent)
5. **HTTPS ingress** configured on the cluster

## Quick Start

```powershell
# 1. Install prerequisites (Longhorn + GPU Operator)
.\demo5-video-indexer\scripts\install-prereqs.ps1 -EnvFile .env

# 2. Deploy the Video Indexer Arc extension
.\demo5-video-indexer\scripts\deploy-vi-extension.ps1 -EnvFile .env

# 3. Add your RTSP camera
.\demo5-video-indexer\scripts\manage-camera.ps1 -Action add -EnvFile .env

# 4. Open the VI portal in your browser
# https://<VI_ENDPOINT_URI>
```

## Camera Requirements

| Requirement | Value |
|-------------|-------|
| Protocol | RTSP (continuous) |
| Frame Rate | 28–32 FPS |
| Resolution | Min 640×480, recommended 1280×720 or 1920×1080 |
| Type | Static only (no PTZ, no fisheye) |
| Color | RGB |
| RTCP | Must support sender reports |

**Recommended camera:** Reolink RLC-520A (PoE, native RTSP, ~$50)

## Demo Walkthrough (GEOINT Booth)

See [docs/demo-guide.md](docs/demo-guide.md) for the full 5-minute demo script and talking points.

## GPU Capacity (NVIDIA A2)

| Scenario | Cameras Supported |
|----------|-------------------|
| Streaming + Recording + Insights | 1–4 |
| Streaming + Insights | 1–4 |
| Insights Only | 1–4 |

> **Note:** Agentic intelligence and event summarization require H100 GPUs and are not available on A2.

## Env Vars

| Variable | Description |
|----------|-------------|
| `VI_ACCOUNT_NAME` | Azure AI Video Indexer account name |
| `VI_ACCOUNT_RESOURCE_GROUP` | Resource group of the VI account |
| `VI_ACCOUNT_ID` | VI account ID (GUID) |
| `VI_EXTENSION_NAME` | Name for the Arc extension |
| `VI_ENDPOINT_URI` | HTTPS endpoint for the extension |
| `VI_STORAGE_CLASS` | RWX storage class name |
| `VI_GPU_TOLERATION_KEY` | GPU toleration key |
| `CAMERA_NAME` | Friendly name for the camera |
| `CAMERA_RTSP_URL` | Full RTSP URL of the camera |

## References

- [Azure AI Video Indexer real-time analysis](https://learn.microsoft.com/en-us/azure/azure-video-indexer/live-analysis)
- [Manage VI extensions](https://learn.microsoft.com/en-us/azure/azure-video-indexer/live-extension)
- [Custom AI insights catalog](https://learn.microsoft.com/en-us/azure/azure-video-indexer/live-ai-insights-catalog)
- [Area of interest](https://learn.microsoft.com/en-us/azure/azure-video-indexer/live-area-interest)
- [Camera management](https://learn.microsoft.com/en-us/azure/azure-video-indexer/live-add-remove-camera)
- [Azure-Samples/azure-video-indexer-samples](https://github.com/Azure-Samples/azure-video-indexer-samples)
