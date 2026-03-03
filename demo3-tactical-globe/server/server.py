"""
GEOINT Demo — Tactical Globe: SSE Proxy Server
===============================================
Lightweight FastAPI server that:
  - Proxies the SSE alert stream from the alert processor to browser clients,
    avoiding cross-origin issues.
  - Exposes a REST endpoint returning the last 50 alerts.
  - Serves the static CesiumJS client from ``/app/public``.

Endpoints:
    GET /api/alerts/stream — SSE proxy; re-emits events from alert processor.
    GET /api/alerts        — Last 50 alerts (proxied from alert processor).
    GET /health            — Liveness probe.
    GET /                  — Static CesiumJS client (index.html + assets).

Environment Variables:
    ALERT_PROCESSOR_URL  Base URL of the alert processor service
                         (default: http://alert-processor:8080)
    PORT                 HTTP port to bind on (default: 3000)
    STATIC_DIR           Directory to serve static client files from
                         (default: /app/public)
"""

from __future__ import annotations

import json
import logging
import os
import sys
from datetime import datetime, timezone
from typing import Any, AsyncGenerator

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

# ---------------------------------------------------------------------------
# Structured JSON logging (matches alert-processor pattern)
# ---------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO, stream=sys.stdout)


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record: dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "level": level.upper(),
        "service": "tactical-globe-server",
        "message": msg,
        **kwargs,
    }
    print(json.dumps(record), flush=True)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ALERT_PROCESSOR_URL: str = os.environ.get(
    "ALERT_PROCESSOR_URL", "http://alert-processor:8080"
)
PORT: int = int(os.environ.get("PORT", "3000"))
STATIC_DIR: str = os.environ.get("STATIC_DIR", "/app/public")

# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------
app = FastAPI(title="GEOINT Tactical Globe Server", version="1.0.0")


@app.get("/health")
async def health() -> JSONResponse:
    """Liveness / readiness probe."""
    return JSONResponse({"status": "ok", "service": "tactical-globe-server"})


@app.get("/api/alerts")
async def api_alerts() -> JSONResponse:
    """
    Proxy the last 50 alerts from the alert processor.
    Returns an empty list if the alert processor is unreachable.
    """
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{ALERT_PROCESSOR_URL}/alerts")
            resp.raise_for_status()
            return JSONResponse(resp.json())
    except httpx.HTTPError as exc:
        _log("warning", "Could not reach alert processor", error=str(exc))
        return JSONResponse([])


@app.get("/api/alerts/stream")
async def api_alerts_stream(request: Request) -> StreamingResponse:
    """
    SSE proxy endpoint.  Connects to the alert processor SSE stream and
    re-emits each event to the connected browser client.  Handles
    disconnect gracefully and shows a status comment when the upstream
    service is unreachable so the browser does not crash.
    """
    _log("info", "SSE proxy client connected")

    async def generator() -> AsyncGenerator[str, None]:
        try:
            async with httpx.AsyncClient(timeout=None) as client:
                async with client.stream(
                    "GET", f"{ALERT_PROCESSOR_URL}/alerts/stream"
                ) as response:
                    async for chunk in response.aiter_text():
                        if await request.is_disconnected():
                            break
                        yield chunk
        except httpx.HTTPError as exc:
            _log(
                "warning",
                "Alert processor SSE stream unreachable",
                error=str(exc),
            )
            # Inform the browser client without crashing the connection
            yield ": alert-processor unreachable — retrying via client\n\n"
        finally:
            _log("info", "SSE proxy client disconnected")

    return StreamingResponse(generator(), media_type="text/event-stream")


# ---------------------------------------------------------------------------
# Static file serving — must be mounted LAST so API routes take priority
# ---------------------------------------------------------------------------
if os.path.isdir(STATIC_DIR):
    app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")
else:
    _log(
        "warning",
        "Static directory not found; static serving disabled",
        static_dir=STATIC_DIR,
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn

    _log(
        "info",
        "Starting tactical globe server",
        port=PORT,
        alert_processor_url=ALERT_PROCESSOR_URL,
        static_dir=STATIC_DIR,
    )
    uvicorn.run("server:app", host="0.0.0.0", port=PORT, log_level="info")
