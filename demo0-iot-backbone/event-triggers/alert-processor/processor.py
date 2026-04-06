"""
GEOINT Demo — IoT Backbone: Alert Processor
============================================
FastAPI service that receives anomaly alert payloads from the Azure IoT
Operations data pipeline and triggers downstream vision pipeline jobs.

Endpoints:
    POST /trigger  — Receive alert payload, dispatch vision pipeline job.
    GET  /health   — Liveness / readiness probe.
    GET  /alerts   — Return last 50 alerts (in-memory ring buffer).

Environment Variables:
    VISION_PIPELINE_URL  URL for demo1 vision pipeline job API
                         (default: http://demo1-vision-service:8080/jobs)
    ALERT_PROCESSOR_PORT HTTP port to bind on (default: 8080)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import uuid
from collections import deque
from datetime import datetime, timezone
from typing import Any, Deque, Optional

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from paho.mqtt import client as mqtt
from pydantic import BaseModel, ValidationError

# ---------------------------------------------------------------------------
# Structured JSON logging
# ---------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO, stream=sys.stdout)
logger = logging.getLogger("alert-processor")


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record: dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "level": level.upper(),
        "service": "alert-processor",
        "message": msg,
        **kwargs,
    }
    print(json.dumps(record), flush=True)


def _env_flag(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VISION_PIPELINE_URL: str = os.environ.get(
    "VISION_PIPELINE_URL", "http://demo1-vision-service:8080/jobs"
)
MAX_VISION_RETRIES: int = int(os.environ.get("MAX_VISION_RETRIES", "3"))
VISION_RETRY_BASE_DELAY: float = float(os.environ.get("VISION_RETRY_BASE_DELAY", "1.0"))
PORT: int = int(os.environ.get("ALERT_PROCESSOR_PORT", "8080"))
MQTT_BRIDGE_ENABLED: bool = _env_flag("MQTT_ALERT_BRIDGE_ENABLED", True)
MQTT_ALERT_HOST: str = os.environ.get("MQTT_ALERT_HOST", "aio-broker-nodeport")
MQTT_ALERT_PORT: int = int(os.environ.get("MQTT_ALERT_PORT", "1883"))
MQTT_ALERT_TOPIC: str = os.environ.get(
    "MQTT_ALERT_TOPIC", "geoint/pipelines/alerts"
)
MQTT_ALERT_USERNAME: Optional[str] = os.environ.get("MQTT_ALERT_USERNAME")
MQTT_ALERT_PASSWORD: Optional[str] = os.environ.get("MQTT_ALERT_PASSWORD")

# In-memory ring buffer — last 50 alerts
_alert_buffer: Deque[dict[str, Any]] = deque(maxlen=50)
_mqtt_client: Optional[mqtt.Client] = None
_event_loop: Optional[asyncio.AbstractEventLoop] = None

# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------


class AlertPayload(BaseModel):
    """Schema of the alert message published by the sensor simulator."""

    sensor_id: str
    sensor_type: str
    grid_ref: str
    lat: float
    lon: float
    timestamp: str
    reading: dict[str, Any]
    alert: bool


class TriggerResponse(BaseModel):
    status: str
    job_id: str


# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------
app = FastAPI(title="GEOINT Alert Processor", version="1.0.0")


async def process_alert(payload: AlertPayload) -> TriggerResponse:
    """Shared alert handling logic for HTTP and MQTT inputs."""
    if not payload.alert:
        raise HTTPException(status_code=400, detail="Payload alert field is false")

    job_id = str(uuid.uuid4())
    alert_record: dict[str, Any] = {
        "job_id": job_id,
        "received_at": datetime.now(timezone.utc).isoformat(),
        **payload.model_dump(),
    }
    _alert_buffer.append(alert_record)
    _log(
        "info",
        "Alert received",
        sensor_id=payload.sensor_id,
        sensor_type=payload.sensor_type,
        grid_ref=payload.grid_ref,
        job_id=job_id,
    )

    # Dispatch vision pipeline job (best-effort — do not block on failure)
    job_request = {
        "job_id": job_id,
        "grid_ref": payload.grid_ref,
        "lat": payload.lat,
        "lon": payload.lon,
        "trigger_sensor": payload.sensor_id,
        "trigger_type": payload.sensor_type,
        "triggered_at": payload.timestamp,
    }
    for attempt in range(MAX_VISION_RETRIES):
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.post(VISION_PIPELINE_URL, json=job_request)
                resp.raise_for_status()
                _log("info", "Vision pipeline job dispatched", job_id=job_id, status=resp.status_code)
                break
        except httpx.HTTPError as exc:
            if attempt < MAX_VISION_RETRIES - 1:
                delay = VISION_RETRY_BASE_DELAY * (2 ** attempt)
                _log(
                    "warning",
                    "Vision pipeline dispatch failed, retrying",
                    attempt=attempt + 1,
                    max_retries=MAX_VISION_RETRIES,
                    retry_delay_s=delay,
                    url=VISION_PIPELINE_URL,
                    error=str(exc),
                    job_id=job_id,
                )
                await asyncio.sleep(delay)
            else:
                _log(
                    "warning",
                    "Could not reach vision pipeline after retries (non-fatal)",
                    attempts=MAX_VISION_RETRIES,
                    url=VISION_PIPELINE_URL,
                    error=str(exc),
                    job_id=job_id,
                )

    return TriggerResponse(status="triggered", job_id=job_id)


@app.post("/trigger", response_model=TriggerResponse)
async def trigger(payload: AlertPayload) -> TriggerResponse:
    """
    Receive an alert payload from IoT Operations, log it, and dispatch a
    vision pipeline job for the affected grid reference.
    """
    return await process_alert(payload)


@app.get("/health")
async def health() -> JSONResponse:
    """Liveness / readiness probe."""
    return JSONResponse({"status": "ok", "service": "alert-processor"})


@app.get("/alerts")
async def list_alerts() -> JSONResponse:
    """Return the last 50 alerts from the in-memory ring buffer."""
    return JSONResponse(list(_alert_buffer))


def _should_start_mqtt_bridge() -> bool:
    return MQTT_BRIDGE_ENABLED and bool(MQTT_ALERT_TOPIC)


def _schedule_alert_from_mqtt(payload: AlertPayload) -> None:
    if _event_loop is None:
        _log("warning", "MQTT bridge not initialized; dropping alert")
        return

    future = asyncio.run_coroutine_threadsafe(process_alert(payload), _event_loop)

    def _handle_future_result(task: asyncio.Future) -> None:
        try:
            task.result()
        except HTTPException as exc:  # pragma: no cover - logged for observability
            _log(
                "warning",
                "MQTT alert rejected",
                status=exc.status_code,
                detail=exc.detail,
            )
        except Exception as exc:  # pragma: no cover - defensive logging
            _log("error", "MQTT alert processing failed", error=str(exc))

    future.add_done_callback(_handle_future_result)


def _on_mqtt_connect(
    client: mqtt.Client,
    _userdata: Any,
    _flags: dict[str, Any],
    reason_code: int,
    _properties: Any = None,
) -> None:
    if reason_code == 0:
        client.subscribe(MQTT_ALERT_TOPIC, qos=1)
        _log(
            "info",
            "MQTT alert bridge connected",
            host=MQTT_ALERT_HOST,
            port=MQTT_ALERT_PORT,
            topic=MQTT_ALERT_TOPIC,
        )
    else:
        _log(
            "warning",
            "MQTT alert bridge failed to connect",
            code=reason_code,
            host=MQTT_ALERT_HOST,
            port=MQTT_ALERT_PORT,
        )


def _on_mqtt_disconnect(client: mqtt.Client, _userdata: Any, reason_code: int) -> None:
    _log(
        "info",
        "MQTT alert bridge disconnected",
        code=reason_code,
        host=MQTT_ALERT_HOST,
    )


def _on_mqtt_message(
    _client: mqtt.Client,
    _userdata: Any,
    message: mqtt.MQTTMessage,
) -> None:
    try:
        decoded = message.payload.decode("utf-8")
        data = json.loads(decoded)
    except UnicodeDecodeError as exc:
        _log("warning", "MQTT payload decode failed", error=str(exc))
        return
    except json.JSONDecodeError as exc:
        _log("warning", "MQTT payload is not valid JSON", error=str(exc))
        return

    if not data.get("alert"):
        return

    try:
        payload = AlertPayload(**data)
    except ValidationError as exc:
        _log("warning", "MQTT payload failed schema validation", error=str(exc))
        return

    _schedule_alert_from_mqtt(payload)


async def _start_mqtt_bridge() -> None:
    if not _should_start_mqtt_bridge():
        _log("info", "MQTT alert bridge disabled via configuration")
        return

    global _mqtt_client, _event_loop
    if _mqtt_client is not None:
        return

    _event_loop = asyncio.get_running_loop()
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.on_connect = _on_mqtt_connect
    client.on_message = _on_mqtt_message
    client.on_disconnect = _on_mqtt_disconnect
    if MQTT_ALERT_USERNAME:
        client.username_pw_set(MQTT_ALERT_USERNAME, MQTT_ALERT_PASSWORD)

    try:
        client.connect_async(MQTT_ALERT_HOST, MQTT_ALERT_PORT, keepalive=60)
        client.loop_start()
        _mqtt_client = client
    except Exception as exc:  # pragma: no cover - connectivity failure
        _log("error", "Failed to start MQTT alert bridge", error=str(exc))


def _stop_mqtt_bridge() -> None:
    global _mqtt_client
    if _mqtt_client is None:
        return

    _mqtt_client.loop_stop()
    _mqtt_client.disconnect()
    _mqtt_client = None
    _log("info", "MQTT alert bridge stopped")


@app.on_event("startup")
async def _on_startup() -> None:
    await _start_mqtt_bridge()


@app.on_event("shutdown")
async def _on_shutdown() -> None:
    _stop_mqtt_bridge()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn

    _log("info", "Starting alert processor", port=PORT, vision_pipeline_url=VISION_PIPELINE_URL)
    uvicorn.run("processor:app", host="0.0.0.0", port=PORT, log_level="info")
