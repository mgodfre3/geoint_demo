"""
GEOINT Demo — IoT Backbone: Sensor Simulator
=============================================
Asyncio-based MQTT publisher that reads a scenario JSON file and continuously
publishes synthetic sensor telemetry to an Azure IoT Operations MQTT Broker.

Supported sensor types: weather-station, seismic, rf-detector.

Environment Variables:
    MQTT_HOST          MQTT broker hostname or IP  (default: localhost)
    MQTT_PORT          MQTT broker port            (default: 1883)
    MQTT_USERNAME      MQTT username               (default: geoint-demo)
    MQTT_PASSWORD      MQTT password               (default: "")
    SCENARIO_FILE      Path to scenario JSON       (default: scenarios/base_scenario.json)
    SENSOR_COUNT       Override sensor count       (default: from scenario file)
    LOOP               Repeat scenario forever     (default: true)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import random
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import paho.mqtt.client as mqtt

# ---------------------------------------------------------------------------
# Logging (structured JSON)
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("sensor-simulator")


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record: dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "level": level.upper(),
        "message": msg,
        **kwargs,
    }
    print(json.dumps(record), flush=True)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MQTT_HOST: str = os.environ.get("MQTT_HOST", "localhost")
MQTT_PORT: int = int(os.environ.get("MQTT_PORT", "1883"))
MQTT_USERNAME: str = os.environ.get("MQTT_USERNAME", "geoint-demo")
MQTT_PASSWORD: str = os.environ.get("MQTT_PASSWORD", "")
SCENARIO_FILE: str = os.environ.get("SCENARIO_FILE", "scenarios/base_scenario.json")
SENSOR_COUNT_OVERRIDE: int | None = (
    int(os.environ["SENSOR_COUNT"]) if "SENSOR_COUNT" in os.environ else None
)
LOOP: bool = os.environ.get("LOOP", "true").lower() not in ("false", "0", "no")

# MQTT topic templates
TOPIC_TELEMETRY = "geoint/sensors/{sensor_type}/{sensor_id}/telemetry"
TOPIC_ALERT = "geoint/sensors/{sensor_type}/{sensor_id}/alert"
TOPIC_STATUS = "geoint/sensors/status"


# ---------------------------------------------------------------------------
# Payload generators
# ---------------------------------------------------------------------------

def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _build_reading(sensor_type: str, anomaly: bool) -> dict[str, Any]:
    """Return a realistic reading dict for the given sensor type."""
    if sensor_type == "weather-station":
        base_temp = 22.0 if not anomaly else random.uniform(35.0, 45.0)
        return {
            "temperature_c": round(base_temp + random.uniform(-0.5, 0.5), 2),
            "humidity_pct": round(random.uniform(30, 90), 1),
            "wind_speed_kph": round(random.uniform(0, 60 if anomaly else 30), 1),
            "pressure_hpa": round(random.uniform(995, 1025), 1),
        }
    elif sensor_type == "seismic":
        mag = random.uniform(2.5, 5.5) if anomaly else random.uniform(0.0, 0.8)
        return {
            "magnitude": round(mag, 2),
            "depth_m": round(random.uniform(5, 35), 1),
            "frequency_hz": round(random.uniform(1.0, 20.0), 2),
        }
    elif sensor_type == "rf-detector":
        power = random.uniform(-40, -10) if anomaly else random.uniform(-90, -60)
        return {
            "frequency_mhz": round(random.uniform(300, 3000), 1),
            "power_dbm": round(power, 1),
            "bandwidth_khz": round(random.uniform(10, 200), 1),
            "modulation": random.choice(["AM", "FM", "BPSK", "QPSK"]),
        }
    return {}


def _build_payload(sensor: dict[str, Any], anomaly: bool) -> dict[str, Any]:
    """Construct the canonical sensor telemetry payload."""
    return {
        "sensor_id": sensor["sensor_id"],
        "sensor_type": sensor["sensor_type"],
        "grid_ref": sensor["grid_ref"],
        "lat": sensor["lat"],
        "lon": sensor["lon"],
        "timestamp": _now_iso(),
        "reading": _build_reading(sensor["sensor_type"], anomaly),
        "alert": anomaly,
    }


# ---------------------------------------------------------------------------
# MQTT client helpers
# ---------------------------------------------------------------------------

def _create_client() -> mqtt.Client:
    client = mqtt.Client(client_id=f"simulator-{uuid.uuid4().hex[:8]}", protocol=mqtt.MQTTv311)
    if MQTT_USERNAME:
        client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)

    def _on_connect(c: mqtt.Client, _userdata: Any, _flags: Any, rc: int) -> None:
        if rc == 0:
            _log("info", "Connected to MQTT broker", host=MQTT_HOST, port=MQTT_PORT)
        else:
            _log("error", "MQTT connection failed", rc=rc)

    def _on_disconnect(c: mqtt.Client, _userdata: Any, rc: int) -> None:
        _log("warning", "Disconnected from MQTT broker", rc=rc)

    client.on_connect = _on_connect
    client.on_disconnect = _on_disconnect
    return client


# ---------------------------------------------------------------------------
# Scenario loading
# ---------------------------------------------------------------------------

def _load_scenario(path: str) -> dict[str, Any]:
    """Load and validate a scenario JSON file."""
    scenario_path = Path(path)
    if not scenario_path.exists():
        # Try relative to this script's directory
        scenario_path = Path(__file__).parent / path
    with scenario_path.open() as fh:
        scenario: dict[str, Any] = json.load(fh)
    _log("info", "Scenario loaded", file=str(scenario_path), name=scenario.get("name"))
    return scenario


def _expand_sensors(scenario: dict[str, Any], count_override: int | None) -> list[dict[str, Any]]:
    """Return the list of sensors, optionally overriding count."""
    sensors: list[dict[str, Any]] = scenario.get("sensors", [])
    if count_override and count_override > len(sensors):
        # Duplicate existing sensors with new IDs to reach desired count
        templates = sensors.copy()
        extra_idx = 0
        while len(sensors) < count_override:
            tpl = templates[extra_idx % len(templates)].copy()
            tpl["sensor_id"] = f"{tpl['sensor_type']}-{len(sensors):03d}"
            sensors.append(tpl)
            extra_idx += 1
    elif count_override:
        sensors = sensors[:count_override]
    return sensors


# ---------------------------------------------------------------------------
# Main simulation loop
# ---------------------------------------------------------------------------

async def _publish_sensor(
    client: mqtt.Client,
    sensor: dict[str, Any],
    anomaly_probability: float,
) -> None:
    """Publish one telemetry (and optionally alert) message for a sensor."""
    anomaly = random.random() < anomaly_probability
    payload = _build_payload(sensor, anomaly)
    topic = TOPIC_TELEMETRY.format(
        sensor_type=sensor["sensor_type"], sensor_id=sensor["sensor_id"]
    )
    result = client.publish(topic, json.dumps(payload), qos=1)
    if result.rc != mqtt.MQTT_ERR_SUCCESS:
        _log("warning", "Publish failed", topic=topic, rc=result.rc)
    else:
        _log("debug", "Published telemetry", topic=topic, alert=anomaly)

    if anomaly:
        alert_topic = TOPIC_ALERT.format(
            sensor_type=sensor["sensor_type"], sensor_id=sensor["sensor_id"]
        )
        client.publish(alert_topic, json.dumps(payload), qos=1)
        _log("info", "Alert published", topic=alert_topic, sensor_id=sensor["sensor_id"])


async def _heartbeat(client: mqtt.Client, sensors: list[dict[str, Any]]) -> None:
    """Publish a heartbeat/status message for all sensors."""
    status = {
        "timestamp": _now_iso(),
        "active_sensors": len(sensors),
        "sensor_ids": [s["sensor_id"] for s in sensors],
    }
    client.publish(TOPIC_STATUS, json.dumps(status), qos=0)
    _log("info", "Heartbeat published", active_sensors=len(sensors))


async def run_simulation(scenario: dict[str, Any], sensors: list[dict[str, Any]]) -> None:
    """Run the main simulation loop."""
    client = _create_client()
    client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
    client.loop_start()

    # Wait for connection
    for _ in range(20):
        if client.is_connected():
            break
        await asyncio.sleep(0.5)
    else:
        _log("error", "Could not connect to MQTT broker — exiting")
        client.loop_stop()
        return

    anomaly_probability: float = scenario.get("anomaly_probability", 0.05)
    publish_interval: float = scenario.get("publish_interval_s", 2.0)
    heartbeat_interval: float = scenario.get("heartbeat_interval_s", 30.0)
    last_heartbeat: float = 0.0

    iteration = 0
    try:
        while True:
            iteration += 1
            _log("info", "Simulation tick", iteration=iteration, sensors=len(sensors))

            tasks = [
                _publish_sensor(client, sensor, anomaly_probability) for sensor in sensors
            ]
            await asyncio.gather(*tasks)

            now = time.monotonic()
            if now - last_heartbeat >= heartbeat_interval:
                await _heartbeat(client, sensors)
                last_heartbeat = now

            await asyncio.sleep(publish_interval)

            if not LOOP:
                _log("info", "LOOP=false — exiting after one pass")
                break
    finally:
        client.loop_stop()
        client.disconnect()
        _log("info", "Simulator stopped")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    """Load scenario and start the simulation."""
    scenario = _load_scenario(SCENARIO_FILE)
    sensors = _expand_sensors(scenario, SENSOR_COUNT_OVERRIDE)
    _log(
        "info",
        "Starting sensor simulator",
        mqtt_host=MQTT_HOST,
        mqtt_port=MQTT_PORT,
        scenario=SCENARIO_FILE,
        sensor_count=len(sensors),
        loop=LOOP,
    )
    asyncio.run(run_simulation(scenario, sensors))


if __name__ == "__main__":
    main()
