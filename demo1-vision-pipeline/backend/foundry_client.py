"""Foundry Local client — async wrapper around the OpenAI-compatible API.

Foundry Local runs as a container exposing an OpenAI-compatible REST API.
This module provides typed helpers for vision analysis and health checks.
"""

import os
import json
import base64
import logging
from typing import Any

import httpx

logger = logging.getLogger(__name__)

FOUNDRY_URL = os.getenv("FOUNDRY_URL", "http://localhost:5273")
FOUNDRY_MODEL = os.getenv("FOUNDRY_MODEL", "microsoft/Phi-3.5-vision-instruct")

_CHAT_ENDPOINT = "/v1/chat/completions"
_MODELS_ENDPOINT = "/v1/models"

# Sensible defaults for satellite imagery workloads
_DEFAULT_TIMEOUT = 15  # seconds — fail fast if model not loaded
_MAX_TOKENS = 1024


async def analyze_image(
    image_bytes: bytes,
    prompt: str = "Describe what you see in this satellite image. Identify any vehicles, buildings, ships, or infrastructure.",
) -> dict[str, Any]:
    """Send an image to the Foundry Local vision model for analysis.

    Args:
        image_bytes: Raw image bytes (JPEG/PNG).
        prompt: Text prompt sent alongside the image.

    Returns:
        The full chat completion response dict on success, or an error dict.
    """
    b64_image = base64.b64encode(image_bytes).decode("utf-8")

    payload = {
        "model": FOUNDRY_MODEL,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{b64_image}"},
                    },
                ],
            }
        ],
        "max_tokens": _MAX_TOKENS,
    }

    try:
        async with httpx.AsyncClient(timeout=_DEFAULT_TIMEOUT) as client:
            response = await client.post(
                f"{FOUNDRY_URL}{_CHAT_ENDPOINT}",
                json=payload,
            )
            response.raise_for_status()
            return response.json()
    except httpx.TimeoutException:
        logger.error("Foundry Local request timed out after %ds", _DEFAULT_TIMEOUT)
        return {"error": "timeout", "detail": "Foundry Local request timed out"}
    except httpx.ConnectError:
        logger.error("Cannot connect to Foundry Local at %s", FOUNDRY_URL)
        return {"error": "connection_refused", "detail": f"Cannot reach Foundry Local at {FOUNDRY_URL}"}
    except httpx.HTTPStatusError as exc:
        logger.error("Foundry Local returned HTTP %d", exc.response.status_code)
        return {"error": "http_error", "detail": f"HTTP {exc.response.status_code}", "status_code": exc.response.status_code}


async def describe_detections(detections_json: dict[str, Any]) -> dict[str, Any]:
    """Ask the LLM to produce a tactical intelligence summary from YOLOv8 detections.

    Args:
        detections_json: YOLOv8 detection output (list of bounding boxes, classes, scores).

    Returns:
        The chat completion response dict or an error dict.
    """
    summary_prompt = (
        "You are a geospatial intelligence analyst. "
        "Given the following object detection results from satellite imagery, "
        "provide a concise tactical intelligence summary. "
        "Highlight any militarily significant objects, patterns of life, or anomalies.\n\n"
        f"Detection results:\n```json\n{json.dumps(detections_json, indent=2)}\n```"
    )

    payload = {
        "model": FOUNDRY_MODEL,
        "messages": [{"role": "user", "content": summary_prompt}],
        "max_tokens": _MAX_TOKENS,
    }

    try:
        async with httpx.AsyncClient(timeout=_DEFAULT_TIMEOUT) as client:
            response = await client.post(
                f"{FOUNDRY_URL}{_CHAT_ENDPOINT}",
                json=payload,
            )
            response.raise_for_status()
            return response.json()
    except httpx.TimeoutException:
        logger.error("Foundry Local request timed out after %ds", _DEFAULT_TIMEOUT)
        return {"error": "timeout", "detail": "Foundry Local request timed out"}
    except httpx.ConnectError:
        logger.error("Cannot connect to Foundry Local at %s", FOUNDRY_URL)
        return {"error": "connection_refused", "detail": f"Cannot reach Foundry Local at {FOUNDRY_URL}"}
    except httpx.HTTPStatusError as exc:
        logger.error("Foundry Local returned HTTP %d", exc.response.status_code)
        return {"error": "http_error", "detail": f"HTTP {exc.response.status_code}", "status_code": exc.response.status_code}


async def health_check() -> dict[str, Any]:
    """Check connectivity to Foundry Local by querying the models endpoint.

    Returns:
        ``{"healthy": True, "models": [...]}`` on success, or
        ``{"healthy": False, "detail": "..."}`` on failure.
    """
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            response = await client.get(f"{FOUNDRY_URL}{_MODELS_ENDPOINT}")
            response.raise_for_status()
            data = response.json()
            return {"healthy": True, "models": data.get("data", [])}
    except httpx.TimeoutException:
        return {"healthy": False, "detail": "Foundry Local health check timed out"}
    except httpx.ConnectError:
        return {"healthy": False, "detail": f"Cannot reach Foundry Local at {FOUNDRY_URL}"}
    except httpx.HTTPStatusError as exc:
        return {"healthy": False, "detail": f"HTTP {exc.response.status_code}"}
