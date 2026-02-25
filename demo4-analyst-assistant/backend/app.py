"""GEOINT Analyst AI Assistant — RAG-powered chat backend

Connects to Foundry Local for LLM inference and ChromaDB for
retrieval-augmented generation over GEOINT reports.
"""

import os
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import httpx
import chromadb

app = FastAPI(
    title="GEOINT Analyst Assistant",
    description="RAG-powered GEOINT analyst chat assistant via Foundry Local",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

FOUNDRY_URL = os.getenv("FOUNDRY_URL", "http://localhost:5273")
CHROMA_URL = os.getenv("CHROMA_URL", "http://localhost:8000")
VISION_API_URL = os.getenv("VISION_API_URL", "http://localhost:8082")
FOUNDRY_MODEL = os.getenv("FOUNDRY_MODEL", "microsoft/Phi-4-mini")

# ChromaDB client
chroma_client = chromadb.HttpClient(host=CHROMA_URL.replace("http://", "").split(":")[0],
                                      port=int(CHROMA_URL.split(":")[-1]))


class ChatRequest(BaseModel):
    message: str
    context_window: int = 5
    include_detections: bool = True


class ChatResponse(BaseModel):
    response: str
    sources: list[dict] = []
    detections: list[dict] = []


@app.get("/health")
async def health():
    return {"status": "healthy", "service": "analyst-assistant"}


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    """Process analyst query with RAG context from GEOINT reports."""

    # Retrieve relevant context from vector store
    sources = []
    context_text = ""
    try:
        collection = chroma_client.get_or_create_collection("geoint_reports")
        results = collection.query(
            query_texts=[request.message],
            n_results=request.context_window,
        )
        if results and results["documents"]:
            for i, doc in enumerate(results["documents"][0]):
                context_text += f"\n[Source {i+1}]: {doc}\n"
                sources.append({
                    "id": results["ids"][0][i] if results["ids"] else f"src-{i}",
                    "text": doc[:200],
                    "metadata": results["metadatas"][0][i] if results["metadatas"] else {},
                })
    except Exception:
        context_text = ""

    # Fetch recent detections if requested
    detections = []
    detection_context = ""
    if request.include_detections:
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                det_response = await client.get(f"{VISION_API_URL}/detections/latest")
                if det_response.status_code == 200:
                    det_data = det_response.json()
                    features = det_data.get("features", [])
                    if features:
                        detections = features
                        lines = []
                        for i, f in enumerate(features):
                            props = f.get("properties", {})
                            coords = f.get("geometry", {}).get("coordinates", [[]])[0]
                            center_lon = sum(c[0] for c in coords) / max(len(coords), 1)
                            center_lat = sum(c[1] for c in coords) / max(len(coords), 1)
                            lines.append(
                                f"  - Detection {i+1}: {props.get('label', 'unknown')} "
                                f"(confidence {props.get('confidence', 0):.0%}) "
                                f"at ({center_lat:.4f}, {center_lon:.4f})"
                            )
                        detection_context = (
                            "\n\n--- RECENT AI DETECTIONS ---\n"
                            f"Total detections: {len(features)}\n"
                            + "\n".join(lines) + "\n"
                            "--- END DETECTIONS ---"
                        )
        except Exception:
            pass

    # Build prompt with RAG context
    system_prompt = """You are a GEOINT analyst assistant deployed on Azure Local infrastructure.
You help analysts interpret geospatial intelligence data, satellite imagery analysis results,
and tactical information. You have access to local intelligence reports and AI detection results.
Be concise, professional, and use standard intelligence terminology.
When referencing source documents, cite them as [Source N]."""

    messages = [
        {"role": "system", "content": system_prompt},
    ]

    if context_text:
        messages.append({
            "role": "system",
            "content": f"Relevant intelligence context:\n{context_text}",
        })

    if detection_context:
        messages.append({
            "role": "system",
            "content": detection_context,
        })

    messages.append({"role": "user", "content": request.message})

    # Call Foundry Local
    async with httpx.AsyncClient(timeout=120) as client:
        response = await client.post(
            f"{FOUNDRY_URL}/v1/chat/completions",
            json={
                "model": FOUNDRY_MODEL,
                "messages": messages,
                "max_tokens": 1024,
                "temperature": 0.3,
            },
        )

    if response.status_code != 200:
        raise HTTPException(status_code=502, detail="Foundry Local unavailable")

    result = response.json()
    assistant_message = result["choices"][0]["message"]["content"]

    return ChatResponse(
        response=assistant_message,
        sources=sources,
        detections=detections,
    )
