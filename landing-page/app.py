import json
import os
from datetime import datetime

import requests
from flask import Flask, jsonify, send_from_directory

app = Flask(__name__, static_folder="static", static_url_path="")

DEFAULT_SERVICES = [
    {
        "name": "Vision Pipeline",
        "description": "YOLOv8 + Foundry Local (Demo 1)",
        "url": "http://vision.den.geoint.local:8081",
        "health": "http://vision.den.geoint.local:8082/health",
    },
    {
        "name": "Geospatial Platform",
        "description": "GeoServer + MapLibre (Demo 2)",
        "url": "http://geo.den.geoint.local:8083",
        "health": "http://geo.den.geoint.local:8083",
    },
    {
        "name": "Tactical Globe",
        "description": "Cesium 3D globe (Demo 3)",
        "url": "http://globe.den.geoint.local:8085",
        "health": "http://globe.den.geoint.local:8085",
    },
    {
        "name": "Analyst Assistant",
        "description": "Foundry Local RAG (Demo 4)",
        "url": "http://analyst.den.geoint.local:8086",
        "health": "http://analyst.den.geoint.local:8086",
    },
]


def _load_services() -> list[dict[str, str]]:
    raw = os.environ.get("SERVICE_CONFIG")
    if not raw:
        return DEFAULT_SERVICES
    try:
        services = json.loads(raw)
        if isinstance(services, list):
            return services
    except json.JSONDecodeError:
        pass
    return DEFAULT_SERVICES


SERVICES = _load_services()


@app.get("/api/health")
def api_health() -> tuple[str, int] | tuple[dict[str, list[dict[str, str | bool]]], int]:
    payload: list[dict[str, str | bool]] = []
    for svc in SERVICES:
        health_url = svc.get("health") or svc.get("url")
        healthy = False
        latency_ms: float | None = None
        try:
            start = datetime.now()
            resp = requests.get(health_url, timeout=3)
            healthy = resp.ok
            latency_ms = (datetime.now() - start).total_seconds() * 1000
        except requests.RequestException:
            healthy = False
        payload.append(
            {
                "name": svc.get("name"),
                "description": svc.get("description"),
                "url": svc.get("url"),
                "healthy": healthy,
                "latency": latency_ms,
            }
        )
    return jsonify({"services": payload})


@app.route("/")
@app.route("/<path:path>")
def index(path: str | None = None):  # type: ignore[override]
    if path and os.path.exists(os.path.join(app.static_folder, path)):
        return send_from_directory(app.static_folder, path)
    return send_from_directory(app.static_folder, "index.html")


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
