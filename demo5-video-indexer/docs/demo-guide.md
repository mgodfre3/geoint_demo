# Demo 5 — GEOINT Booth Demo Guide

## Tactical Edge Perimeter Intelligence — Fully Disconnected AI

### Narrative

> *"Imagine you've deployed a tactical mobile command post — no cloud, limited power, hostile environment. You need real-time situational awareness from surveillance cameras. This is exactly what we're running: Azure AI Video Indexer on a Mobile Cluster with a single NVIDIA A2 GPU. No internet. All AI at the edge."*

---

## Pre-Show Setup Checklist

- [ ] Mobile Cluster powered on and AKS Arc healthy (`kubectl get nodes`)
- [ ] Video Indexer extension running (`kubectl get pods -n video-indexer`)
- [ ] Camera mounted and RTSP stream verified
- [ ] Laptop connected to cluster network
- [ ] VI web portal accessible at `https://<VI_ENDPOINT_URI>`
- [ ] Custom insights pre-configured (see below)
- [ ] Area of interest drawn on booth perimeter

## Pre-Configured Custom Insights

### 1. Badge Holder (Object Insight)
- **Description:** "Person wearing a visible lanyard or identification badge"
- **Sample images:** 5–10 photos of people wearing conference badges

### 2. Unattended Object (Situation Insight)
- **Description:** "A bag, briefcase, or backpack stationary on the floor with no person nearby"

### 3. Crowd Gathering (Situation Insight)
- **Description:** "A group of three or more people standing together in a cluster"

### 4. Perimeter Entry Zone (Area of Interest)
- Draw a polygon over the booth entrance
- Metric: Person count (entry/exit)

---

## 5-Minute Demo Script

### 0:00–0:30 — The Hardware
> "This is a 2-node Azure Local cluster — Lenovo SE350s with NVIDIA A2 GPUs. Compact, tactical-class hardware. Running Azure AI Video Indexer entirely at the edge via Azure Arc."

### 0:30–1:30 — Live Detection
Show the VI portal with live feed and bounding boxes. Each person gets a unique tracking ID.

### 1:30–2:30 — Perimeter Zone
Show the area-of-interest polygon with person counter. Ask a visitor to walk through.

### 2:30–3:30 — Custom Threat Detection
Show custom insight detections. "Using natural language, we defined 'unattended backpack' and 'crowd gathering'. No ML training needed."

### 3:30–4:30 — Recorded Footage
Navigate to recorded footage, scrub to a detected event.

### 4:30–5:00 — Architecture Wrap-Up
"Zero cloud dependency. Single 40W GPU. Full data sovereignty. Azure Arc manages when connected."

---

## Q&A Talking Points

| Question | Answer |
|----------|--------|
| "Does it need internet?" | No — runs locally after initial setup. Arc manages when connected. |
| "How many cameras?" | A2 supports 1–4. Use A10/A100/H100 for more. |
| "Custom objects?" | Yes — natural language + a few example images. |
| "Classified video?" | All data stays on-cluster. Zero cloud upload. |
| "How fast?" | Real-time at 30 FPS. Sub-second latency. |
| "DDIL?" | Yes — designed for disconnected environments. |
