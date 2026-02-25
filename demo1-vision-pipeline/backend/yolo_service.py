"""YOLOv8 Satellite Object Detection Service

Sidecar container providing REST API for satellite/aerial imagery
object detection. Runs alongside Foundry Local in the AKS pod.

Default model: yolov8n.pt (nano). Swap MODEL_PATH env var to use
a fine-tuned satellite-specific model.
"""

import os
import io
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import JSONResponse
from PIL import Image
from ultralytics import YOLO

logger = logging.getLogger("yolo_service")
logging.basicConfig(level=logging.INFO)

MODEL_PATH = os.getenv("YOLO_MODEL_PATH", "yolov8n.pt")

# Satellite/aerial imagery target classes.
# Standard COCO classes are mapped to domain-specific names when possible.
SATELLITE_CLASS_MAP: dict[int, str] = {
    0: "person",
    1: "bicycle",
    2: "vehicle",       # car -> vehicle
    3: "vehicle",       # motorcycle -> vehicle
    4: "aircraft",      # airplane -> aircraft
    5: "bus",
    6: "vehicle",       # train -> vehicle
    7: "vehicle",       # truck -> vehicle
    8: "ship",          # boat -> ship
    14: "bird",
    15: "cat",
    16: "dog",
    24: "backpack",
    56: "chair",
    60: "dining-table",
    62: "tv",
    63: "laptop",
}

# Classes of interest for satellite/aerial imagery analysis
SATELLITE_CLASSES = {
    "vehicle", "ship", "aircraft", "building", "storage-tank",
    "helicopter", "small-vehicle", "large-vehicle", "plane", "harbor",
    "person", "bus",
}

model: YOLO | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load the YOLO model on startup."""
    global model
    logger.info("Loading YOLOv8 model from %s ...", MODEL_PATH)
    model = YOLO(MODEL_PATH)
    logger.info("Model loaded successfully. Classes: %s", list(model.names.values())[:10])
    yield
    logger.info("Shutting down YOLO service.")


app = FastAPI(
    title="YOLOv8 Satellite Detection Service",
    description="Object detection sidecar for satellite/aerial imagery",
    version="1.0.0",
    lifespan=lifespan,
)


def _map_class_name(class_id: int, default_name: str) -> str:
    """Map COCO class id to satellite-domain name."""
    return SATELLITE_CLASS_MAP.get(class_id, default_name)


@app.get("/health")
async def health():
    """Liveness / readiness probe."""
    return {
        "status": "healthy",
        "service": "yolo-detection",
        "model": MODEL_PATH,
        "model_loaded": model is not None,
    }


@app.post("/predict")
async def predict(
    image: UploadFile = File(...),
    confidence: float = Form(0.25),
):
    """Run YOLOv8 inference on an uploaded image.

    Returns detections with bounding boxes, class names, and confidence
    scores filtered to the requested confidence threshold.
    """
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    try:
        contents = await image.read()
        img = Image.open(io.BytesIO(contents)).convert("RGB")
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid image file")

    results = model.predict(source=img, conf=confidence, verbose=False)
    result = results[0]

    detections = []
    for box in result.boxes:
        class_id = int(box.cls[0])
        raw_name = result.names[class_id]
        mapped_name = _map_class_name(class_id, raw_name)
        x1, y1, x2, y2 = box.xyxy[0].tolist()

        detections.append({
            "bbox": {
                "x1": round(x1, 2),
                "y1": round(y1, 2),
                "x2": round(x2, 2),
                "y2": round(y2, 2),
            },
            "class_name": mapped_name,
            "class_id": class_id,
            "confidence": round(float(box.conf[0]), 4),
        })

    return JSONResponse(content={
        "detections": detections,
        "count": len(detections),
        "image_size": {"width": img.width, "height": img.height},
        "model": MODEL_PATH,
        "confidence_threshold": confidence,
    })
