"""GEOINT Analyst AI Assistant — RAG-powered chat backend

Connects to Foundry Local for LLM inference and ChromaDB for
retrieval-augmented generation over GEOINT reports.
"""

import os
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
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


CHAT_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>GEOINT Analyst Assistant</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0a0a0a;color:#e0e0e0;font-family:'Segoe UI',system-ui,sans-serif;height:100vh;display:flex;flex-direction:column}
header{background:linear-gradient(135deg,#1a1a2e,#16213e);padding:16px 24px;border-bottom:2px solid #0078d4;display:flex;align-items:center;gap:16px}
header h1{font-size:20px;color:#fff}
.badge{font-size:11px;padding:2px 8px;border-radius:10px;font-weight:600}
.badge-azure{background:#0078d4;color:#fff}
.badge-live{background:#00c853;color:#000}
.container{display:flex;flex:1;overflow:hidden}
.chat-panel{flex:2;display:flex;flex-direction:column;border-right:1px solid #222}
.sidebar{flex:1;padding:16px;overflow-y:auto;max-width:320px}
.messages{flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:12px}
.msg{padding:12px 16px;border-radius:8px;max-width:85%;line-height:1.5;font-size:14px;white-space:pre-wrap}
.msg-user{background:#0078d4;color:#fff;align-self:flex-end}
.msg-assistant{background:#1a1a2e;border:1px solid #333;align-self:flex-start}
.input-bar{padding:12px 16px;border-top:1px solid #222;display:flex;gap:8px}
.input-bar input{flex:1;padding:10px 14px;border-radius:6px;border:1px solid #333;background:#111;color:#e0e0e0;font-size:14px;outline:none}
.input-bar input:focus{border-color:#0078d4}
.input-bar button{padding:10px 20px;border-radius:6px;border:none;background:#0078d4;color:#fff;font-weight:600;cursor:pointer}
.input-bar button:disabled{opacity:.5;cursor:not-allowed}
.sidebar h3{color:#aaa;font-size:13px;text-transform:uppercase;margin-bottom:12px}
.quick-btn{display:block;width:100%;text-align:left;padding:10px 12px;margin-bottom:8px;border-radius:6px;border:1px solid #333;background:#111;color:#ccc;cursor:pointer;font-size:13px}
.quick-btn:hover{border-color:#0078d4;color:#fff}
.source-card{background:#1a1a2e;border:1px solid #333;border-radius:6px;padding:10px;margin-bottom:8px;font-size:12px}
.source-card strong{color:#0078d4}
.spinner{display:inline-block;width:16px;height:16px;border:2px solid #333;border-top-color:#0078d4;border-radius:50%;animation:spin .6s linear infinite;margin-right:8px;vertical-align:middle}
@keyframes spin{to{transform:rotate(360deg)}}
.typing{padding:12px 16px;color:#888;font-size:13px;align-self:flex-start}
</style>
</head>
<body>
<header>
<h1>&#127758; GEOINT Analyst Assistant</h1>
<span class="badge badge-azure">Azure Local</span>
<span class="badge badge-live">LIVE</span>
</header>
<div class="container">
<div class="chat-panel">
<div class="messages" id="messages">
<div class="msg msg-assistant">Welcome! I'm your GEOINT analyst assistant powered by AI on Azure Local. Ask me about geospatial intelligence, satellite imagery analysis, or tactical information.</div>
</div>
<div class="input-bar">
<input type="text" id="input" placeholder="Ask about geospatial intelligence..." autocomplete="off"/>
<button id="send" onclick="sendMessage()">Send</button>
</div>
</div>
<div class="sidebar">
<h3>Quick Queries</h3>
<button class="quick-btn" onclick="ask(this.textContent)">What objects were detected near the port?</button>
<button class="quick-btn" onclick="ask(this.textContent)">Summarize activity in the observation zone</button>
<button class="quick-btn" onclick="ask(this.textContent)">What facilities are near NGA headquarters?</button>
<button class="quick-btn" onclick="ask(this.textContent)">Show recent detection alerts</button>
<button class="quick-btn" onclick="ask(this.textContent)">Assess current threat level in the AOR</button>
<div id="sources-section" style="margin-top:24px;display:none">
<h3>Sources</h3>
<div id="sources"></div>
</div>
</div>
</div>
<script>
const msgs=document.getElementById('messages'),inp=document.getElementById('input'),btn=document.getElementById('send');
inp.addEventListener('keydown',e=>{if(e.key==='Enter'&&!btn.disabled)sendMessage()});
function ask(t){inp.value=t;sendMessage()}
function addMsg(role,text){const d=document.createElement('div');d.className='msg msg-'+role;d.textContent=text;msgs.appendChild(d);msgs.scrollTop=msgs.scrollHeight}
async function sendMessage(){
const text=inp.value.trim();if(!text)return;
inp.value='';addMsg('user',text);
btn.disabled=true;
const typing=document.createElement('div');typing.className='typing';typing.innerHTML='<span class="spinner"></span>Analyzing...';msgs.appendChild(typing);msgs.scrollTop=msgs.scrollHeight;
try{
const r=await fetch('/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({message:text})});
typing.remove();
if(!r.ok)throw new Error('API error '+r.status);
const data=await r.json();
addMsg('assistant',data.response);
if(data.sources&&data.sources.length){
const sec=document.getElementById('sources-section');sec.style.display='block';
const sc=document.getElementById('sources');sc.innerHTML='';
data.sources.forEach(s=>{const c=document.createElement('div');c.className='source-card';c.innerHTML='<strong>'+s.id+'</strong><br>'+s.text;sc.appendChild(c)});
}
}catch(e){typing.remove();addMsg('assistant','Error: '+e.message)}
btn.disabled=false;inp.focus();
}
</script>
</body>
</html>"""


@app.get("/", response_class=HTMLResponse)
async def root():
    return CHAT_HTML
