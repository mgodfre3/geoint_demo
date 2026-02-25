# Event Runbook — GEOINT 2026 Symposium Demo

> **Audience:** Event staff setting up and operating the GEOINT demo at a booth or kiosk.
>
> **Hardware:** 2× Lenovo SE350 (each: NVIDIA A2 GPU, 128 GB RAM, internet-connected)
>
> **Related docs:** [Architecture](architecture.md) · [Setup Guide](setup-guide.md)

---

## Table of Contents

1. [Pre-Event Checklist](#1-pre-event-checklist)
2. [Day-Of Setup](#2-day-of-setup)
3. [Demo Operation](#3-demo-operation)
4. [Teardown](#4-teardown)
5. [Troubleshooting Guide](#5-troubleshooting-guide)

---

## 1. Pre-Event Checklist

Complete these items **before** leaving for the event venue.

### 1.1 Hardware Verification

- [ ] Both SE350 nodes power on and POST successfully
- [ ] NVIDIA A2 GPU seated and detected on each node (`nvidia-smi` shows the card)
- [ ] All 128 GB RAM recognized per node
- [ ] NVMe/SSD storage healthy — no SMART warnings
- [ ] Network ports functional (test with cable on both NICs)
- [ ] Peripherals packed: 2× power cables, 2× Ethernet cables, 1× HDMI/DP cable per monitor, USB keyboard + mouse

### 1.2 Software Pre-Loaded

- [ ] Azure Local cluster deployed and healthy — `Get-AzureStackHCI` shows `Connected`
- [ ] Arc-Enabled AKS cluster provisioned with GPU passthrough enabled
- [ ] Flux GitOps configured and synced — `kubectl get kustomization -n flux-system` shows `Ready`
- [ ] VMs for Demo 2 (GeoServer/PostGIS) and Demo 3 (CesiumJS Globe) are created and reachable
- [ ] Docker Compose stacks tested on both VMs
- [ ] All four demo UIs load correctly in a browser

### 1.3 Container Images Pre-Cached in ACR

Run the ACR push script and verify all images exist:

```powershell
.\scripts\setup-acr.ps1 -AcrName acrgeointdemo

# Verify images
az acr repository list --name acrgeointdemo --output table
```

Expected repositories:

| Image | Demo |
|-------|------|
| `demo1-backend` | AI Vision Pipeline |
| `demo1-yolo` | AI Vision Pipeline (YOLOv8) |
| `demo4-backend` | Analyst AI Assistant |
| `demo4-frontend` | Analyst AI Assistant |

### 1.4 Network Requirements

| Requirement | Details |
|-------------|---------|
| **Ports (outbound)** | 443 (Azure Arc, ACR), 80/443 (optional — Cesium ion tiles) |
| **Ports (inbound on booth LAN)** | 8081–8086 (demo UIs, see [Architecture](architecture.md)) |
| **Bandwidth** | ≥ 10 Mbps sustained (ACR pulls, Arc heartbeat, Cesium tiles) |
| **DNS** | Resolve `*.azurecr.io`, `*.guestconfiguration.azure.com`, `management.azure.com`, `ion.cesium.com` |
| **Firewall** | Allow WebSocket on 8085 (Cesium globe live updates) |

### 1.5 Backup Plan — Intermittent Internet

If internet is unreliable at the venue:

1. **ACR images are already cached** on nodes — AKS pods will restart from local cache (`imagePullPolicy: IfNotPresent`).
2. **Cesium ion tiles** — pre-download a regional tile set to TileServer GL on the Globe VM so Demo 3 works offline.
3. **Arc heartbeat** will reconnect automatically; demo functionality is unaffected during outages.
4. **AI models** run entirely on-device via Foundry Local — no cloud dependency.
5. Bring a **mobile hotspot** as a last-resort fallback for connectivity.

---

## 2. Day-Of Setup

**Estimated time:** 30–45 minutes from power-on to demo-ready.

### 2.1 Physical Setup

1. Place both SE350 nodes on the table/rack behind or under the booth counter.
2. Connect **power cables** to each node and to booth power (verify circuit capacity ≥ 15A / 120V).
3. Connect **Ethernet** from each node to the booth network switch (or venue drop).
4. Connect **monitors**: HDMI/DP from each node (or from a single laptop driving both via extended display).
5. Connect **USB keyboard + mouse** to one node (for initial checks; remove after setup).

### 2.2 Boot Sequence

1. Power on **Node 1** first, wait for OS login prompt (~2 min).
2. Power on **Node 2**.
3. Log in to each node and verify basic health:

```powershell
# On each node — check cluster status
Get-AzureStackHCI
```

Expected: `ConnectionStatus: Connected`, `ImdsAttestation: Connected`.

### 2.3 Verify Azure Arc Connectivity

```powershell
az connectedk8s show --resource-group rg-geoint-demo --name geoint-aks --query connectivityStatus
```

Expected output: `"Connected"`. If `"Offline"`, check network and wait 2–3 minutes for reconnection.

### 2.4 Verify AKS Pods (Demos 1 & 4)

```bash
# Connect to AKS
kubectl get nodes -o wide

# Check all pods are Running
kubectl get pods -A | grep -E "demo1|demo4"

# Verify GPU allocation
kubectl describe nodes | grep -A5 "nvidia.com/gpu"
```

All pods should show `Running` with `1/1` ready. If any are in `CrashLoopBackOff`, see [Troubleshooting](#5-troubleshooting-guide).

### 2.5 Verify VM Services (Demos 2 & 3)

**Demo 2 — GeoServer/PostGIS (Node 1 VM):**

```bash
ssh user@<vm-geoserver-ip>
cd /opt/geoint/demo2-geo-platform
docker compose ps
```

All containers should show `Up`. If not:

```bash
docker compose up -d
```

**Demo 3 — CesiumJS Globe (Node 2 VM):**

```bash
ssh user@<vm-globe-ip>
cd /opt/geoint/demo3-tactical-globe
docker compose ps
# Start if needed
docker compose up -d
```

### 2.6 Load Sample Data

If data has not been pre-loaded (first-time setup):

```powershell
.\scripts\seed-data.ps1
```

This loads satellite imagery tiles, PostGIS vector features, and GEOINT reports into Demo 4's vector store.

### 2.7 Open Demo UIs in Browser Kiosk Mode

On the demo laptop/monitor, open each URL in kiosk (full-screen) mode:

```powershell
# Chrome kiosk mode — one window per monitor
Start-Process chrome "--kiosk http://<node1-ip>:8081"   # Demo 1 — Vision Pipeline
Start-Process chrome "--kiosk http://<node1-ip>:8083"   # Demo 2 — Geo Platform
Start-Process chrome "--kiosk http://<node2-ip>:8085"   # Demo 3 — Tactical Globe
Start-Process chrome "--kiosk http://<node2-ip>:8086"   # Demo 4 — Analyst Assistant
```

> **Tip:** Use `--new-window` instead of `--kiosk` if you need to switch between demos on a single monitor.

### 2.8 Final Smoke Test

Visit each URL and confirm:

- [ ] Demo 1: Upload page loads, can drag-and-drop an image
- [ ] Demo 2: MapLibre map renders with base layer tiles
- [ ] Demo 3: Cesium globe renders and simulated tracks animate
- [ ] Demo 4: Chat UI loads and responds to a test question

---

## 3. Demo Operation

### 3.1 Demo URLs

| # | Demo | URL | Type |
|---|------|-----|------|
| 1 | AI Vision Pipeline | `http://<node1-ip>:8081` | AKS (GPU) |
| 2 | Geospatial Platform | `http://<node1-ip>:8083` | VM |
| 3 | 3D Tactical Globe | `http://<node2-ip>:8085` | VM |
| 4 | Analyst AI Assistant | `http://<node2-ip>:8086` | AKS (GPU) |

### 3.2 Talking Points & Interaction Guide

#### Demo 1 — AI Vision Pipeline

**Talking Points:**
- AI object detection running entirely at the edge — YOLOv8 + Foundry Local vision model on NVIDIA A2 GPU, no cloud round-trip needed.
- Processes satellite imagery in seconds, annotating vehicles, buildings, and infrastructure with bounding boxes.
- Built on Arc-Enabled AKS with GitOps deployment — same enterprise Kubernetes management, deployed to tactical edge hardware.

**Live Interaction:**
1. Drag-and-drop a sample satellite image onto the upload area.
2. Wait ~3–5 seconds for inference to complete.
3. Show the annotated result with bounding boxes and confidence scores.
4. Point out the inference time displayed — emphasize low-latency edge processing.

#### Demo 2 — Geospatial Platform

**Talking Points:**
- Full OGC-compliant geospatial stack at the edge — GeoServer, PostGIS, TileServer GL.
- Interactive MapLibre GL JS viewer with standard WMS/WFS services that any GIS tool can consume.
- Demonstrates that GEOINT data infrastructure doesn't need a data center — runs on two small-form-factor servers.

**Live Interaction:**
1. Pan and zoom the map to different regions.
2. Toggle vector layers on/off to show AI detection overlays.
3. Click features to show attribute popups (e.g., detection type, confidence, timestamp).

#### Demo 3 — 3D Tactical Globe

**Talking Points:**
- CesiumJS 3D globe with live-simulated sensor coverage, moving tracks, and AI-detected objects.
- Runs in auto-play kiosk mode — great for ambient booth display or live narration.
- WebSocket-driven real-time updates, showing how a Common Operating Picture can run at the edge.

**Live Interaction:**
1. Let kiosk mode auto-play (rotates globe, shows tracks appearing).
2. Click on a track entity to show details.
3. Use mouse to fly to a specific area of interest and show sensor coverage overlays.

#### Demo 4 — Analyst AI Assistant

**Talking Points:**
- Foundry Local SLM with RAG over classified-style intelligence reports — entirely on-device, no data leaves the edge.
- Analysts can ask natural-language questions and get sourced answers from the document corpus.
- ChromaDB vector store for embedding-based retrieval — runs on the same compact hardware.

**Live Interaction:**
1. Type a question like: *"What activity has been detected near the port in the last 24 hours?"*
2. Show the AI response with cited source documents.
3. Ask a follow-up question to demonstrate conversational context.
4. Highlight that the model and all data stay on-premises.

### 3.3 Quick Restart Commands

If a service goes down during the demo:

```bash
# Restart a specific AKS pod (Demo 1 or 4)
kubectl delete pod -l app=demo1-backend        # pod auto-recreates
kubectl delete pod -l app=demo4-backend

# Restart VM Docker services (Demo 2)
ssh user@<vm-geoserver-ip> "cd /opt/geoint/demo2-geo-platform && docker compose restart"

# Restart VM Docker services (Demo 3)
ssh user@<vm-globe-ip> "cd /opt/geoint/demo3-tactical-globe && docker compose restart"
```

---

## 4. Teardown

### 4.1 Graceful Shutdown Sequence

Perform in this order to avoid data corruption:

1. **Close all browser windows** on the demo laptop.

2. **Stop VM workloads:**

```bash
# Demo 2
ssh user@<vm-geoserver-ip> "cd /opt/geoint/demo2-geo-platform && docker compose down"

# Demo 3
ssh user@<vm-globe-ip> "cd /opt/geoint/demo3-tactical-globe && docker compose down"
```

3. **AKS pods** — leave them running (Flux will manage them). If you need a clean stop:

```bash
kubectl scale deployment --all --replicas=0 -n demo1
kubectl scale deployment --all --replicas=0 -n demo4
```

4. **Shut down VMs** from the Azure portal or:

```powershell
az stack-hci-vm stop --resource-group rg-geoint-demo --name vm-geoserver
az stack-hci-vm stop --resource-group rg-geoint-demo --name vm-globe
```

5. **Power off nodes** — use the OS shutdown command, then flip power switches:

```powershell
Stop-Computer -Force   # Run on each node
```

### 4.2 Data Cleanup

- **Demo 4 chat history:** Cleared automatically on pod restart. No action needed.
- **Uploaded images (Demo 1):** Stored in pod ephemeral storage — cleared on restart.
- **PostGIS data (Demo 2):** Persistent. Only delete if resetting for another event:

```bash
ssh user@<vm-geoserver-ip> "cd /opt/geoint/demo2-geo-platform && docker compose down -v"
```

### 4.3 Packing Checklist

- [ ] 2× Lenovo SE350 nodes (powered off)
- [ ] 2× Power cables
- [ ] 2× Ethernet cables
- [ ] Monitor cables (HDMI/DP)
- [ ] USB keyboard + mouse
- [ ] Booth switch / networking gear
- [ ] Demo laptop (if separate from nodes)
- [ ] Mobile hotspot (backup connectivity)
- [ ] Printed quick-reference card (demo URLs + talking points)

---

## 5. Troubleshooting Guide

### 5.1 Common Issues

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Pod stuck in `Pending` | GPU not allocated | `kubectl describe pod <name>` — check for GPU resource errors. Verify `nvidia-smi` on node. Restart GPU device plugin: `kubectl delete pod -n kube-system -l name=nvidia-device-plugin-ds` |
| Pod in `CrashLoopBackOff` | OOM or config error | `kubectl logs <pod> --previous` to see crash reason. Check RAM limits in deployment YAML. |
| Pod in `ImagePullBackOff` | ACR unreachable or auth expired | Check internet connectivity. Re-authenticate: `az acr login --name acrgeointdemo`. Verify `imagePullPolicy: IfNotPresent` for offline resilience. |
| Demo 2 map shows no tiles | TileServer GL container down | `ssh user@<vm-geoserver-ip> "docker compose ps"` — restart if needed. |
| Demo 3 globe blank | WebSocket blocked or Cesium container down | Check firewall allows port 8085 WebSocket. Restart: `docker compose restart`. |
| Demo 4 chat returns errors | Foundry Local model not loaded | `kubectl logs -l app=demo4-backend` — look for model loading errors. Delete pod to trigger reload. |
| Slow inference (Demo 1) | GPU not being used | `kubectl exec <pod> -- nvidia-smi` to verify GPU utilization. If 0%, restart the pod. |
| Browser shows "connection refused" | Service not started or wrong IP | Verify IP with `kubectl get svc` or `hostname -I` on VMs. Ensure ports 8081–8086 are open. |
| Arc shows "Offline" | Internet or DNS issue | Check DNS resolution: `nslookup management.azure.com`. Check proxy settings. Arc will auto-reconnect. |

### 5.2 Health Check URLs

| Service | Health URL | Expected |
|---------|-----------|----------|
| Demo 1 — Vision Frontend | `http://<node1-ip>:8081` | HTML page loads |
| Demo 1 — Inference API | `http://<node1-ip>:8082/health` | `{"status": "ok"}` |
| Demo 2 — GeoServer | `http://<node1-ip>:8084/geoserver/web/` | GeoServer admin UI |
| Demo 2 — MapLibre Viewer | `http://<node1-ip>:8083` | Map renders |
| Demo 3 — CesiumJS Globe | `http://<node2-ip>:8085` | Globe renders |
| Demo 4 — Chat UI | `http://<node2-ip>:8086` | Chat interface loads |

### 5.3 GPU Status Check

```bash
# On AKS node (via pod exec or SSH)
nvidia-smi

# Expected: NVIDIA A2, 16 GB VRAM, processes listed for running workloads

# Check GPU allocation in Kubernetes
kubectl describe nodes | grep -A5 "nvidia.com/gpu"
# Should show: Allocated: 1
```

### 5.4 Pod Status & Logs

```bash
# All pods
kubectl get pods -A -o wide

# Logs for a specific demo
kubectl logs -l app=demo1-backend --tail=50
kubectl logs -l app=demo4-backend --tail=50

# Previous crash logs
kubectl logs -l app=demo1-backend --previous
```

### 5.5 Container Logs (VM Workloads)

```bash
# Demo 2
ssh user@<vm-geoserver-ip> "cd /opt/geoint/demo2-geo-platform && docker compose logs --tail=50"

# Demo 3
ssh user@<vm-globe-ip> "cd /opt/geoint/demo3-tactical-globe && docker compose logs --tail=50"
```

### 5.6 Emergency: Full Cluster Restart

If everything is unresponsive, perform a full restart:

1. **Power-cycle both nodes** (hold power button 5 sec if unresponsive, then power on).
2. Wait ~5 minutes for OS boot and Azure Local cluster services to start.
3. Verify cluster:

```powershell
Get-AzureStackHCI
Get-ClusterNode
```

4. Verify AKS:

```bash
kubectl get nodes
kubectl get pods -A
```

5. If pods are not auto-recovering, force a Flux reconciliation:

```bash
flux reconcile kustomization geoint-flux --with-source
```

6. Restart VM workloads:

```bash
# Start VMs if they didn't auto-start
az stack-hci-vm start --resource-group rg-geoint-demo --name vm-geoserver
az stack-hci-vm start --resource-group rg-geoint-demo --name vm-globe

# Then start Docker services
ssh user@<vm-geoserver-ip> "cd /opt/geoint/demo2-geo-platform && docker compose up -d"
ssh user@<vm-globe-ip> "cd /opt/geoint/demo3-tactical-globe && docker compose up -d"
```

7. Re-open browser kiosk windows (see [Section 2.7](#27-open-demo-uis-in-browser-kiosk-mode)).

---

> **Questions?** Contact the demo engineering team before the event for a dry-run walkthrough.
