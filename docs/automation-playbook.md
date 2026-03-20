# GEOINT Demo Automation Playbook

Sales teams need the stack running continuously with zero terminal work. This playbook explains how to install the provided systemd units, keep telemetry flowing, and surface one-click health checks.

## 1. Prerequisites

- Ubuntu 22.04 on both VMs (`geo` and `globe`) with Docker Engine ≥ 24.x.
- Python 3.10+ on the node hosting the sensor simulator (can be the Geo VM).
- Repository cloned to `/opt/geoint` on each host.
- `.env.denver` (or site-specific env file) populated with correct IPs and credentials.

## 2. Static MQTT Endpoint

1. Ensure the AKS worker IP (`172.22.84.50` per `.env.denver`) is reachable from both VMs.
2. Update DNS (`mqtt.den.geoint.local`) to point at that IP. The NodePort 31883 exposed by IoT Operations remains constant.
3. `demo2-geo-platform/.env` now references the static IP so `postgis-ingest` restarts without kubectl proxies.

## 3. Always-On Services via Systemd

Run the helper script from the repo root on each host (requires sudo):

```bash
cd /opt/geoint
sudo ./scripts/install-demo-services.sh <geo|globe|sensor|all>
```

- `geo` installs `demo2-geoplatform.service` (GeoServer/PostGIS + landing page stack).
- `globe` installs `demo3-globe.service` (Cesium kiosk).
- `sensor` installs `sensor-simulator.service` and copies its `.env` file.

Each unit is `Restart=always`, so containers or the simulator resume automatically after reboots. Verify with `systemctl status <service>`.

## 4. Landing Page & Health Widget

The new `landing` service (part of the Demo 2 docker-compose stack) publishes a control panel at `http://geo.den.geoint.local:8080`. It pings every demo's health endpoint server-side and renders green/red badges for sales. Access it from any presenter laptop; bookmark it as the "start here" page.

## 5. Daily Operations Checklist (Now Automated)

| Previous Manual Step | Automated Mechanism |
|----------------------|---------------------|
| `kubectl port-forward ... 31883:1883` | Static MQTT endpoint + `.env` update |
| `docker compose up -d` on VMs | systemd units `demo2-geoplatform` & `demo3-globe` |
| Terminal-based sensor simulator | systemd `sensor-simulator` service with restart policy |
| Remembering URLs/IPs | DNS aliases (`vision/geo/globe/analyst/mqtt.den.geoint.local`) + optional landing page |

With these changes, powering on the two nodes auto-starts every service; sales staff only need to open the bookmarked demo URLs.
