"""GEOINT AI Vision Pipeline — FastAPI Backend

Serves satellite imagery analysis via YOLOv8 object detection
and Foundry Local multimodal vision model.
"""

import os
import io
import base64
from typing import Optional

from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import httpx
from PIL import Image

import foundry_client

# In-memory store for latest detection results (GeoJSON)
_latest_detections: list[dict] = []

app = FastAPI(
    title="GEOINT Vision Pipeline",
    description="Satellite imagery object detection powered by YOLOv8 + Foundry Local",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

YOLO_URL = os.getenv("YOLO_URL", "http://localhost:8000")


def _store_detections(detection_result: dict | None):
    """Convert YOLO detections to GeoJSON features and store them."""
    global _latest_detections
    if not detection_result or "detections" not in detection_result:
        return
    features = []
    for det in detection_result["detections"]:
        bbox = det.get("bbox", {})
        lon = det.get("lon", -77.04 + (bbox.get("x1", 0) - 320) * 0.0001)
        lat = det.get("lat", 38.89 + (bbox.get("y1", 0) - 240) * -0.0001)
        half_w = bbox.get("width", det.get("width", 20)) * 0.00005
        half_h = bbox.get("height", det.get("height", 20)) * 0.00005
        features.append({
            "type": "Feature",
            "properties": {
                "label": det.get("label", det.get("class", "unknown")),
                "confidence": det.get("confidence", 0),
            },
            "geometry": {
                "type": "Polygon",
                "coordinates": [[
                    [lon - half_w, lat - half_h],
                    [lon + half_w, lat - half_h],
                    [lon + half_w, lat + half_h],
                    [lon - half_w, lat + half_h],
                    [lon - half_w, lat - half_h],
                ]],
            },
        })
    _latest_detections = features


@app.get("/detections/latest")
async def get_latest_detections():
    """Return the most recent detection results as a GeoJSON FeatureCollection."""
    return {
        "type": "FeatureCollection",
        "features": _latest_detections,
    }


@app.get("/health")
async def health():
    return {"status": "healthy", "service": "vision-pipeline"}


@app.post("/detect")
async def detect_objects(
    image: UploadFile = File(...),
    confidence: float = 0.25,
):
    """Run YOLOv8 object detection on uploaded satellite imagery."""
    contents = await image.read()

    async with httpx.AsyncClient(timeout=60) as client:
        response = await client.post(
            f"{YOLO_URL}/predict",
            files={"image": (image.filename, contents, image.content_type)},
            data={"confidence": str(confidence)},
        )

    if response.status_code != 200:
        raise HTTPException(status_code=502, detail="Detection service unavailable")

    result = response.json()
    _store_detections(result)
    return result


@app.post("/analyze")
async def analyze_image(
    image: UploadFile = File(...),
    prompt: Optional[str] = "Describe what you see in this satellite image. Identify any vehicles, buildings, ships, or infrastructure.",
):
    """Analyze satellite imagery using Foundry Local vision model."""
    contents = await image.read()

    result = await foundry_client.analyze_image(contents, prompt)

    if "error" in result:
        raise HTTPException(status_code=502, detail=result.get("detail", "Foundry Local unavailable"))

    return result


@app.post("/pipeline")
async def full_pipeline(
    image: UploadFile = File(...),
    confidence: float = 0.25,
):
    """Run full pipeline: YOLOv8 detection + Foundry Local analysis."""
    contents = await image.read()

    detection_result = None
    analysis_result = None

    async with httpx.AsyncClient(timeout=120) as client:
        # YOLOv8 detection
        det_response = await client.post(
            f"{YOLO_URL}/predict",
            files={"image": (image.filename, contents, "image/jpeg")},
            data={"confidence": str(confidence)},
        )
        if det_response.status_code == 200:
            detection_result = det_response.json()

        # Foundry Local analysis
        analysis_result = await foundry_client.analyze_image(
            contents,
            "Analyze this satellite image. Describe the terrain, identify visible structures, vehicles, and any notable activity.",
        )
        if "error" in analysis_result:
            analysis_result = None

    _store_detections(detection_result)

    return {
        "detections": detection_result,
        "analysis": analysis_result,
    }
