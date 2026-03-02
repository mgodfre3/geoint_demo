# 📊 Grafana Dashboard — GEOINT IoT Backbone

## Overview

The `grafana-dashboard.json` file is a Grafana dashboard export showing live sensor telemetry from the GEOINT IoT Backbone module.

## Panels

| Panel | Type | Description |
|-------|------|-------------|
| 🛰 Sensor Heartbeat | Table | Last-seen status for each sensor in the fleet |
| ⚠ Alert Count Over Time | Time Series | Anomaly alert frequency per minute |
| 📡 Sensor Type Distribution | Pie Chart | Message breakdown by sensor type |
| 📋 Live Telemetry Feed | Table | Last 20 sensor readings |

## Prerequisites

- Grafana ≥ 10.0 deployed in the `monitoring` namespace (see `GRAFANA_NAMESPACE` in `.env`)
- **Loki** datasource connected to your cluster log aggregator (receives structured JSON logs from the sensor simulator)
- **Prometheus** datasource (optional — for future metric panels)

## Import Instructions

1. Port-forward Grafana to your workstation:
   ```bash
   kubectl port-forward svc/grafana 3000:3000 -n monitoring
   ```

2. Open Grafana at `http://localhost:3000` (default credentials: `admin`/`admin`).

3. Navigate to **Dashboards → Import**.

4. Upload `grafana-dashboard.json` **or** paste its contents into the JSON input box.

5. On the import screen, map the datasource inputs:
   - **Prometheus** → select your Prometheus datasource
   - **Loki** → select your Loki datasource

6. Click **Import**.

## Connecting to a Datasource

If you do not yet have Loki installed:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm upgrade --install loki grafana/loki-stack \
  --namespace monitoring --create-namespace \
  --set promtail.enabled=true
```

The sensor simulator and alert processor both emit structured JSON to `stdout`.  
Promtail (included in `loki-stack`) automatically collects these logs and forwards them to Loki using pod labels.  
The dashboard queries use `{service="sensor-simulator"}` and `{service="alert-processor"}` label selectors.

## Customisation

To adjust the refresh rate, edit the `"refresh"` field in `grafana-dashboard.json` (default: `10s`).
