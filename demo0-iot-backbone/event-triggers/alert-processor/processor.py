"""
GEOINT Demo — IoT Backbone: Alert Processor
============================================
FastAPI service that receives anomaly alert payloads from the Azure IoT
Operations data pipeline and triggers downstream vision pipeline jobs.

Endpoints:
    POST /trigger       — Receive alert payload, dispatch vision pipeline job.
    GET  /health        — Liveness / readiness probe.
    GET  /alerts        — Return last 50 alerts (in-memory ring buffer).
    GET  /alerts/stream — Server-Sent Events stream; push each new alert to
                          all connected subscribers in real time.

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
from typing import Any, AsyncGenerator, Deque

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

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


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VISION_PIPELINE_URL: str = os.environ.get(
    "VISION_PIPELINE_URL", "http://demo1-vision-service:8080/jobs"
)
PORT: int = int(os.environ.get("ALERT_PROCESSOR_PORT", "8080"))

# In-memory ring buffer — last 50 alerts
_alert_buffer: Deque[dict[str, Any]] = deque(maxlen=50)

# SSE subscriber queues — one asyncio.Queue per connected client
_sse_subscribers: list[asyncio.Queue[dict[str, Any]]] = []

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


@app.post("/trigger", response_model=TriggerResponse)
async def trigger(payload: AlertPayload) -> TriggerResponse:
    """
    Receive an alert payload from IoT Operations, log it, and dispatch a
    vision pipeline job for the affected grid reference.
    """
    if not payload.alert:
        raise HTTPException(status_code=400, detail="Payload alert field is false")

    job_id = str(uuid.uuid4())
    alert_record: dict[str, Any] = {
        "job_id": job_id,
        "received_at": datetime.now(timezone.utc).isoformat(),
        **payload.model_dump(),
    }
    _alert_buffer.append(alert_record)
    # Notify all SSE subscribers of the new alert
    for queue in _sse_subscribers.copy():
        await queue.put(alert_record)
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
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(VISION_PIPELINE_URL, json=job_request)
            resp.raise_for_status()
            _log("info", "Vision pipeline job dispatched", job_id=job_id, status=resp.status_code)
    except httpx.HTTPError as exc:
        _log(
            "warning",
            "Could not reach vision pipeline (non-fatal)",
            url=VISION_PIPELINE_URL,
            error=str(exc),
            job_id=job_id,
        )

    return TriggerResponse(status="triggered", job_id=job_id)


@app.get("/health")
async def health() -> JSONResponse:
    """Liveness / readiness probe."""
    return JSONResponse({"status": "ok", "service": "alert-processor"})


@app.get("/alerts")
async def list_alerts() -> JSONResponse:
    """Return the last 50 alerts from the in-memory ring buffer."""
    return JSONResponse(list(_alert_buffer))


@app.get("/alerts/stream")
async def alerts_stream(request: Request) -> StreamingResponse:
    """
    Server-Sent Events endpoint.  Each connected client receives a push
    event every time a new alert is appended to ``_alert_buffer``.
    Clients subscribe once and the connection stays open until they
    disconnect or the server shuts down.

    Event format::

        event: alert
        data: {"job_id": "...", "sensor_id": "...", ...}
    """
    queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
    _sse_subscribers.append(queue)
    _log("info", "SSE client connected", subscriber_count=len(_sse_subscribers))

    async def event_generator() -> AsyncGenerator[str, None]:
        try:
            while not await request.is_disconnected():
                try:
                    alert = await asyncio.wait_for(queue.get(), timeout=15.0)
                    data = json.dumps(alert)
                    yield f"event: alert\ndata: {data}\n\n"
                except asyncio.TimeoutError:
                    # Send a keepalive comment so the connection is not dropped
                    yield ": keepalive\n\n"
        finally:
            _sse_subscribers.remove(queue)
            _log(
                "info",
                "SSE client disconnected",
                subscriber_count=len(_sse_subscribers),
            )

    return StreamingResponse(event_generator(), media_type="text/event-stream")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn

    _log("info", "Starting alert processor", port=PORT, vision_pipeline_url=VISION_PIPELINE_URL)
    uvicorn.run("processor:app", host="0.0.0.0", port=PORT, log_level="info")
