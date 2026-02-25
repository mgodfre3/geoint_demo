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
FOUNDRY_URL = os.getenv("FOUNDRY_URL", "http://localhost:5273")


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

    return response.json()


@app.post("/analyze")
async def analyze_image(
    image: UploadFile = File(...),
    prompt: Optional[str] = "Describe what you see in this satellite image. Identify any vehicles, buildings, ships, or infrastructure.",
):
    """Analyze satellite imagery using Foundry Local vision model."""
    contents = await image.read()
    b64_image = base64.b64encode(contents).decode("utf-8")

    payload = {
        "model": "microsoft/Phi-3.5-vision-instruct",
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
        "max_tokens": 1024,
    }

    async with httpx.AsyncClient(timeout=120) as client:
        response = await client.post(
            f"{FOUNDRY_URL}/v1/chat/completions",
            json=payload,
        )

    if response.status_code != 200:
        raise HTTPException(status_code=502, detail="Foundry Local unavailable")

    return response.json()


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
        b64_image = base64.b64encode(contents).decode("utf-8")
        analysis_payload = {
            "model": "microsoft/Phi-3.5-vision-instruct",
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": "Analyze this satellite image. Describe the terrain, identify visible structures, vehicles, and any notable activity.",
                        },
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/jpeg;base64,{b64_image}"},
                        },
                    ],
                }
            ],
            "max_tokens": 1024,
        }
        ai_response = await client.post(
            f"{FOUNDRY_URL}/v1/chat/completions",
            json=analysis_payload,
        )
        if ai_response.status_code == 200:
            analysis_result = ai_response.json()

    return {
        "detections": detection_result,
        "analysis": analysis_result,
    }
