# 🛰️ Demo 0 — IoT Backbone

> **"A fleet of simulated field sensors publishes telemetry at the edge via MQTT. Azure IoT Operations on Azure Local ingests, routes, and transforms the data — no cloud required. When an anomaly is detected, the event pipeline automatically triggers the AI vision pipeline to analyze imagery of the affected grid reference."**

---

## 🗺️ Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Azure Local Cluster                               │
│                   (2× Lenovo SE350, NVIDIA A2 GPU)                      │
│                                                                          │
│  ┌──────────────────┐       MQTT        ┌───────────────────────────┐   │
│  │  sensor-simulator│ ──────────────▶  │  Azure IoT Operations     │   │
│  │  (K8s Pod)       │  geoint/sensors/  │  MQTT Broker              │   │
│  │                  │  +/+/telemetry    │  (NodePort 31883 / 8883)  │   │
│  │  weather-station │  geoint/sensors/  └──────────┬────────────────┘   │
│  │  seismic         │  +/+/alert                   │                    │
│  │  rf-detector     │                              │ DataFlow           │
│  └──────────────────┘                              │                    │
│                                           ┌────────┴──────────────┐     │
│                                           │  pipeline-sensors     │     │
│                                           │  → PostGIS ingest API │     │
│                                           │                       │     │
│                                           │  pipeline-alerts      │     │
│                                           │  → alert-processor    │     │
│                                           └────────┬──────────────┘     │
│                                                    │ HTTP POST           │
│                                           ┌────────▼──────────────┐     │
│                                           │  alert-processor      │     │
│                                           │  (FastAPI K8s Pod)    │     │
│                                           │  POST /trigger        │     │
│                                           └────────┬──────────────┘     │
│                                                    │ HTTP POST           │
│                                           ┌────────▼──────────────┐     │
│                                           │  demo1-vision-service │     │
│                                           │  POST /jobs           │     │
│                                           └───────────────────────┘     │
│                                                                          │
│  Observability: Loki ← Promtail ← pod logs  →  Grafana Dashboard        │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 Prerequisites

| Requirement | Notes |
|-------------|-------|
| Azure Local cluster | Registered with Azure Arc |
| Arc-Enabled AKS | GPU passthrough not required for demo0 |
| Azure Container Registry | Name set in `ACR_NAME` env var |
| Azure CLI ≥ 2.57 | With `azure-iot-ops`, `connectedk8s`, `k8s-extension` extensions |
| `kubectl` | Configured to target the AKS cluster |
| Docker | For building and pushing container images |
| PowerShell 7+ | For the deployment script |

---

## ⚙️ Configuration

All cluster-specific values live in an `.env` file — **no hardcoded values anywhere**.

```powershell
# Copy the template
cp .env.template .env.staging

# Fill in your cluster values
$EDITOR .env.staging
```

Key IoT Backbone variables (see `.env.template` for the full list):

| Variable | Description | Default |
|----------|-------------|---------|
| `AKS_CLUSTER_NAME` | Arc-connected AKS cluster name | `geoint-aks` |
| `MQTT_BROKER_NODEPORT` | NodePort for MQTT access | `31883` |
| `MQTT_USERNAME` | MQTT broker username | `geoint-demo` |
| `MQTT_PASSWORD` | MQTT broker password | *(set in .env)* |
| `SENSOR_COUNT` | Number of simulated sensors | `12` |
| `SCENARIO_FILE` | Scenario JSON to load | `base_scenario.json` |
| `VISION_PIPELINE_URL` | demo1 vision pipeline endpoint | `http://demo1-vision-service:8080/jobs` |
| `IOT_OPS_EXTENSION_VERSION` | AIO extension version | `1.0.0` |

---

## 🚀 Deployment

```powershell
# Deploy to staging
.\demo0-iot-backbone\infra\deploy-iot-backbone.ps1 -EnvFile .env.staging

# Dry-run (prints all commands, executes nothing)
.\demo0-iot-backbone\infra\deploy-iot-backbone.ps1 -EnvFile .env.staging -DryRun

# Deploy to production (GEOINT 2026)
.\demo0-iot-backbone\infra\deploy-iot-backbone.ps1 -EnvFile .env.prod
```

### What the script does

| Step | Action |
|------|--------|
| 1 | Validate Azure CLI login + required extensions |
| 2–3 | Create `azure-iot-operations` namespace + RBAC |
| 4–5 | Deploy AIO extension via Bicep; wait for `Succeeded` |
| 6 | Create K8s Secrets for MQTT credentials |
| 7 | Apply MQTT Broker, Asset definitions, DataFlow pipelines |
| 8–9 | Build + push `sensor-simulator` and `alert-processor` images to ACR |
| 10 | Apply simulator ConfigMap/Deployment and alert-processor Deployment |

---

## 🔄 Switching Environments

To redeploy to a different cluster:

```powershell
# 1. Create a new env file for the target cluster
cp .env.template .env.prod

# 2. Fill in the production cluster ARM IDs and credentials
notepad .env.prod   # or use your preferred editor

# 3. Run the same script — only the env file changes
.\demo0-iot-backbone\infra\deploy-iot-backbone.ps1 -EnvFile .env.prod
```

**Zero code changes required** — all cluster-specific values come from the `.env` file.

---

## 📡 MQTT Topic Reference

| Topic | Direction | Description |
|-------|-----------|-------------|
| `geoint/sensors/{type}/{id}/telemetry` | Simulator → Broker | Normal sensor reading (every 2–5 s) |
| `geoint/sensors/{type}/{id}/alert` | Simulator → Broker | Anomaly alert (when `alert: true`) |
| `geoint/sensors/status` | Simulator → Broker | Heartbeat — active sensor list (every 30 s) |

**Sensor types:** `weather-station`, `seismic`, `rf-detector`

---

## 📦 Sensor Payload Schema

All topics use the same canonical JSON schema:

```json
{
  "sensor_id":   "seismic-001",
  "sensor_type": "seismic",
  "grid_ref":    "38TLP234567",
  "lat":         38.123,
  "lon":        -77.456,
  "timestamp":  "2026-03-02T12:00:00Z",
  "reading": {
    "magnitude":   0.3,
    "depth_m":    12,
    "frequency_hz": 4.2
  },
  "alert": false
}
```

### Reading fields by sensor type

| Sensor Type | Fields |
|-------------|--------|
| `weather-station` | `temperature_c`, `humidity_pct`, `wind_speed_kph`, `pressure_hpa` |
| `seismic` | `magnitude`, `depth_m`, `frequency_hz` |
| `rf-detector` | `frequency_mhz`, `power_dbm`, `bandwidth_khz`, `modulation` |

---

## 🎬 Scenarios

| File | Description | Anomaly Probability |
|------|-------------|-------------------|
| `base_scenario.json` | Normal baseline telemetry | 4% |
| `convoy_scenario.json` | Ground vehicle convoy simulation | 12% |
| `anomaly_scenario.json` | High-rate RF/seismic anomaly injection | 45% |

Switch scenarios by updating `SCENARIO_FILE` in your `.env` file, then re-running the deployment or patching the ConfigMap:

```bash
kubectl patch configmap sensor-simulator-config \
  -n azure-iot-operations \
  --patch '{"data":{"SCENARIO_FILE":"scenarios/anomaly_scenario.json"}}'

kubectl rollout restart deployment/sensor-simulator -n azure-iot-operations
```

---

## 📊 Grafana Dashboard

```powershell
# 1. Port-forward Grafana
kubectl port-forward svc/grafana 3000:3000 -n monitoring

# 2. Open http://localhost:3000 (admin / admin)
# 3. Dashboards → Import → Upload dashboards/grafana-dashboard.json
# 4. Map datasources: Prometheus + Loki
```

See [`dashboards/README.md`](dashboards/README.md) for full instructions.

---

## 🗑️ Teardown

```powershell
.\demo0-iot-backbone\infra\deploy-iot-backbone.ps1 -EnvFile .env.staging -Teardown
```

This removes all deployed resources in reverse order:
workloads → pipelines → assets → MQTT broker → AIO extension → namespace.
