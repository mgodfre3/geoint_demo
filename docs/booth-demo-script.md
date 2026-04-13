# GEOINT on Azure Local — Booth Demo Script

> **Audience:** Any staff member running the booth at GEOINT 2026  
> **Duration:** 3–5 minutes per walkthrough (loops continuously)  
> **Setup:** Everything is always running. No commands to type. Just open browsers.

---

## The One-Liner

> *"This is a full GEOINT processing stack — sensors, AI vision, mapping, and an analyst assistant — running entirely on two rugged edge nodes with no cloud dependency."*

---

## Before the Show Opens

Open these 4 browser tabs on the demo laptop (bookmark them):

| Tab | URL | What It Shows |
|-----|-----|---------------|
| 🛰️ Vision | `http://172.22.84.50:8081` | Satellite image AI analysis |
| 🗺️ Map | `http://172.22.84.42:8083` | 2D geospatial common operating picture |
| 🌍 Globe | `http://172.22.84.43:8085` | 3D tactical globe (auto-playing) |
| 🤖 Analyst | `http://172.22.84.50:8086` | AI chat assistant |

The **3D Globe** tab should be full-screen on the big monitor — it auto-plays and draws people in.

---

## The 3-Minute Walk-Up Script

When someone walks up, point at the globe and say:

### 1. The Hook (15 seconds)

> *"What you're seeing is a live tactical picture — sensor data, AI detections, and vehicle tracks — all processed on this kit right here. Two small servers, no cloud connection needed."*

### 2. The Sensors (30 seconds)

Point at the map tab. Toggle a layer or click a sensor point.

> *"We have 12 simulated field sensors — seismic, RF, weather — streaming data over MQTT through Azure IoT Operations at the edge. When the seismic array detects ground vibration consistent with heavy vehicles, it automatically triggers the next step."*

### 3. The AI Vision (60 seconds) — ⭐ The Wow Moment

Switch to the Vision tab. Click **Upload** and pick `convoy.png` from the samples.

> *"Here we task the vision pipeline with the latest satellite pass. The AI — a YOLOv8 model plus Microsoft's Phi vision model — runs entirely on the onboard NVIDIA A2 GPU."*

Wait 3–5 seconds for results to appear.

> *"Under five seconds. It found the convoy — trucks, fuel tankers — with confidence scores and bounding boxes. No data left this box."*

### 4. The Map (30 seconds)

Switch to the Map tab. The detections should already be there.

> *"Those detections automatically flow into PostGIS and render on the map alongside the sensor data. Any coalition partner with WMS/WFS access sees the same picture — open standards, no vendor lock-in."*

### 5. The Analyst (45 seconds)

Switch to the Analyst tab. Type or have pre-loaded:

> *"Summarize seismic activity near grid 57S and correlate with vehicle detections."*

> *"The analyst assistant runs a Microsoft Phi-4 language model locally with RAG over intelligence reports. It fuses the new detections with historical data and cites its sources — all on-device."*

### 6. The Close (15 seconds)

> *"Sensors to shooters in one kit. Deploys in minutes via Azure Arc, runs disconnected indefinitely, and when connectivity returns, Arc syncs it all back. Any questions?"*

---

## If They Ask About Video (Demo 5)

Point to the Video Indexer portal if it's running:

> *"We also have Azure AI Video Indexer running at the edge — live RTSP camera feed analyzed in real-time on the GPU. Person detection, perimeter monitoring, threat alerting — all on-prem."*

Portal: `https://denver-vi.adaptivecloudlab.com`

---

## Quick Answers to Common Questions

| They Ask | You Say |
|----------|---------|
| **"What hardware is this?"** | *"Two Lenovo SE350 nodes — each has an NVIDIA A2 GPU, 128 GB RAM. Fits in a ruggedized transit case."* |
| **"What if the network goes down?"** | *"Everything keeps running. AI models, databases, message broker — all local. When WAN returns, Azure Arc re-syncs automatically."* |
| **"What AI models?"** | *"Microsoft Foundry Local — Phi-3.5 Vision for image analysis, Phi-4-mini for the chat assistant, and YOLOv8 for object detection. All running on the A2 GPU."* |
| **"Can we use our own data?"** | *"Absolutely. Sensors publish to standard MQTT topics, imagery goes through a REST API, and GeoServer speaks WMS/WFS for interop."* |
| **"How long to deploy?"** | *"One script, about 30 minutes from bare metal to fully operational. GitOps via Flux keeps it consistent across sites."* |
| **"What about classification?"** | *"Data never leaves the node. All inference is local. Metadata tags support per-layer access control via GeoServer and Entra ID."* |
| **"Is this Azure only?"** | *"The workloads are containers and open standards. Azure Arc manages them, but the apps are Kubernetes-native. GeoServer, PostGIS, MQTT — all open source."* |

---

## Troubleshooting (If Something Looks Wrong)

| Symptom | Quick Fix |
|---------|-----------|
| Globe not animating | Refresh the browser tab (`F5`) |
| Vision upload takes >10s | GPU may be cold — try a second upload, it warms up |
| Map layers missing | Click the layer toggle icon (top-right), re-enable layers |
| Analyst gives generic answer | Rephrase with specific grid references or time ranges |
| Whole demo unreachable | Check laptop is on the booth LAN (same subnet as 172.22.84.x) |

---

## Staff Training Checklist

- [ ] Can you explain the one-liner from memory?
- [ ] Can you find and open all 4 browser tabs?
- [ ] Can you upload an image in the Vision tab and narrate the result?
- [ ] Can you toggle map layers and click a feature?
- [ ] Can you type a question in the Analyst chat?
- [ ] Can you answer the top 3 FAQ questions above?

**If yes to all 6 → you're ready for the booth.** 🎯
