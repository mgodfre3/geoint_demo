from flask import Flask, jsonify, render_template_string
import base64, requests, json, os, time, threading, urllib3
urllib3.disable_warnings()

app = Flask(__name__)

# Config from environment
VI_ENDPOINT = os.environ.get("VI_ENDPOINT", "https://denver-vi.default.svc.cluster.local:8443")
VI_ACCOUNT_ID = os.environ.get("VI_ACCOUNT_ID", "d987d021-dd25-4fec-80af-09631f7c7726")
CAMERA_NAME = os.environ.get("VI_CAMERA_NAME", "geoint-booth-cam")
CAMERA_RTSP_URL = os.environ.get("CAMERA_RTSP_URL", "")

_REFRESH_BUFFER_S = 300  # renew 5 min before expiry

# Token from environment (injected by K8s secret or init container)
_token_cache = {"token": os.environ.get("VI_ACCESS_TOKEN", ""), "expires": 0}
_token_lock = threading.Lock()

_state = {
    "total_count": 0,
    "current_in_frame": 0,
    "peak_count": 0,
    "zone_entries": 0,
    "alert_count": 0,
    "camera_status": "Connecting",
    "camera_id": "",
    "last_detections": [],
    "events": [],
    "spark_data": [0] * 30,
    "resolution": "",
    "vi_counters": {},
}

# Internal tracking state (not JSON-serialized)
_seen_ids = set()
_prev_ids = set()
_prev_det_count = 0


def get_token() -> str:
    return _token_cache.get("token", "")


# ── Token refresh methods (priority order) ────────────────────────────

def _jwt_exp(token: str) -> float:
    """Extract 'exp' claim from a JWT without cryptographic validation."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (4 - len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
        return float(claims.get("exp", 0))
    except Exception:
        return 0.0


def _refresh_via_workload_identity():
    """Azure Workload Identity: exchange projected SA token for AAD token."""
    tenant = os.environ.get("AZURE_TENANT_ID")
    client_id = os.environ.get("AZURE_CLIENT_ID")
    token_file = os.environ.get("AZURE_FEDERATED_TOKEN_FILE")
    authority = os.environ.get("AZURE_AUTHORITY_HOST",
                               "https://login.microsoftonline.com")
    scope = os.environ.get("VI_TOKEN_SCOPE",
                           "https://management.azure.com/.default")
    if not all([tenant, client_id, token_file]):
        return None
    try:
        if not os.path.exists(token_file):
            return None
        with open(token_file) as f:
            assertion = f.read().strip()
        r = requests.post(
            f"{authority}/{tenant}/oauth2/v2.0/token",
            data={
                "grant_type": "client_credentials",
                "client_id": client_id,
                "client_assertion_type":
                    "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                "client_assertion": assertion,
                "scope": scope,
            },
            timeout=15,
        )
        if r.ok:
            data = r.json()
            return (data["access_token"],
                    time.time() + data.get("expires_in", 3600))
    except Exception as e:
        app.logger.error(f"Workload-identity token refresh: {e}")
    return None


def _refresh_via_service_principal():
    """Client-credentials grant using AZURE_CLIENT_SECRET."""
    tenant = os.environ.get("AZURE_TENANT_ID")
    client_id = os.environ.get("AZURE_CLIENT_ID")
    client_secret = os.environ.get("AZURE_CLIENT_SECRET")
    scope = os.environ.get("VI_TOKEN_SCOPE",
                           "https://management.azure.com/.default")
    if not all([tenant, client_id, client_secret]):
        return None
    try:
        r = requests.post(
            f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
            data={
                "grant_type": "client_credentials",
                "client_id": client_id,
                "client_secret": client_secret,
                "scope": scope,
            },
            timeout=15,
        )
        if r.ok:
            data = r.json()
            return (data["access_token"],
                    time.time() + data.get("expires_in", 3600))
    except Exception as e:
        app.logger.error(f"Service-principal token refresh: {e}")
    return None


def _refresh_via_file():
    """Read a token written to disk by an external sidecar / CronJob."""
    token_path = os.environ.get("VI_TOKEN_PATH",
                                "/var/run/secrets/vi-token/token")
    try:
        if os.path.exists(token_path):
            with open(token_path) as f:
                new_token = f.read().strip()
            if new_token:
                exp = _jwt_exp(new_token) or (time.time() + 3600)
                return new_token, exp
    except Exception as e:
        app.logger.error(f"File-based token read: {e}")
    return None


def _do_refresh() -> bool:
    """Try every available method; update cache on first success."""
    for name, method in [
        ("workload-identity", _refresh_via_workload_identity),
        ("service-principal", _refresh_via_service_principal),
        ("file",             _refresh_via_file),
    ]:
        result = method()
        if result:
            token, expires = result
            with _token_lock:
                _token_cache["token"] = token
                _token_cache["expires"] = expires
            app.logger.info(
                f"Token refreshed via {name} "
                f"(expires in {int(expires - time.time())}s)")
            return True
    return False


def token_refresh_loop():
    """Proactively refresh tokens before they expire — runs for days."""
    if _token_cache["token"] and not _token_cache["expires"]:
        exp = _jwt_exp(_token_cache["token"])
        if exp:
            _token_cache["expires"] = exp
            app.logger.info(
                f"Seed token expires in {int(exp - time.time())}s")

    while True:
        try:
            remaining = _token_cache["expires"] - time.time()
            if remaining < _REFRESH_BUFFER_S:
                if _do_refresh():
                    time.sleep(60)
                    continue
                app.logger.warning(
                    "All token refresh methods failed — retrying in 30 s")
                time.sleep(30)
                continue
            time.sleep(min(remaining - _REFRESH_BUFFER_S, 60))
        except Exception as e:
            app.logger.error(f"Token refresh loop: {e}")
            time.sleep(30)


def discover_camera():
    token = get_token()
    if not token:
        return
    try:
        r = requests.get(
            f"{VI_ENDPOINT}/Accounts/{VI_ACCOUNT_ID}/cameras",
            headers={"Authorization": f"Bearer {token}"},
            verify=False, timeout=10
        )
        if r.ok:
            data = r.json()
            cameras = data.get("results", data if isinstance(data, list) else [])
            for cam in cameras:
                if cam.get("name") == CAMERA_NAME:
                    _state["camera_id"] = cam["id"]
                    _state["camera_status"] = cam.get("status", "Unknown")
                    return
            if cameras:
                _state["camera_id"] = cameras[0]["id"]
                _state["camera_status"] = cameras[0].get("status", "Unknown")
    except Exception as e:
        app.logger.error(f"Camera discovery: {e}")


def poll_insights():
    while True:
        try:
            if not _state["camera_id"]:
                discover_camera()
                time.sleep(5)
                continue

            token = get_token()
            if not token:
                _state["camera_status"] = "No token"
                time.sleep(10)
                continue

            r = requests.get(
                f"{VI_ENDPOINT}/Accounts/{VI_ACCOUNT_ID}/cameras/{_state['camera_id']}/insights",
                headers={"Authorization": f"Bearer {token}"},
                verify=False, timeout=10
            )
            if r.ok:
                data = r.json()
                detections = data.get("detections", [])
                people = [d for d in detections if d.get("type", "").lower() in ("person", "people")]
                person_count = len(people)
                _state["current_in_frame"] = person_count
                _state["resolution"] = f"{data.get('width', '?')}x{data.get('height', '?')}"

                # Store raw detection data for visualization
                _state["last_detections"] = [
                    {
                        "type": d.get("type", "object"),
                        "id": d.get("id", ""),
                        "confidence": d.get("confidence", 0),
                        "bbox": d.get("boundingBox", d.get("bbox", {})),
                    }
                    for d in detections
                ]
                _state["frame_width"] = data.get("width", 1920)
                _state["frame_height"] = data.get("height", 1080)

                # Track unique person IDs for accurate counting
                global _seen_ids, _prev_ids, _prev_det_count
                current_ids = {d.get("id") for d in people if d.get("id")}
                entered = current_ids - _prev_ids
                exited = _prev_ids - current_ids

                _seen_ids.update(current_ids)
                _state["total_count"] = len(_seen_ids)
                _prev_ids = current_ids

                if entered:
                    _state["zone_entries"] += len(entered)
                    id_preview = ", ".join(sorted(entered)[:3])
                    suffix = "..." if len(entered) > 3 else ""
                    _state["events"].insert(0, {
                        "type": "person",
                        "text": f"{len(entered)} person(s) entered — {person_count} in frame (IDs: {id_preview}{suffix})",
                        "time": time.strftime("%I:%M:%S %p")
                    })

                if exited:
                    _state["events"].insert(0, {
                        "type": "person",
                        "text": f"{len(exited)} person(s) exited — {person_count} remaining",
                        "time": time.strftime("%I:%M:%S %p")
                    })

                if person_count > _state["peak_count"]:
                    _state["peak_count"] = person_count

                # Detection summary for all types
                all_types = {}
                for d in detections:
                    t = d.get("type", "object").lower()
                    all_types[t] = all_types.get(t, 0) + 1

                if detections and len(detections) != _prev_det_count:
                    summary_parts = [f"{count} {dtype}" for dtype, count in sorted(all_types.items())]
                    _state["events"].insert(0, {
                        "type": "zone",
                        "text": f"AI detecting: {', '.join(summary_parts)}",
                        "time": time.strftime("%I:%M:%S %p")
                    })
                    _prev_det_count = len(detections)

                for sit in data.get("situations", []):
                    _state["alert_count"] += 1
                    _state["events"].insert(0, {
                        "type": "alert",
                        "text": sit.get("type", "Alert"),
                        "time": time.strftime("%I:%M:%S %p")
                    })

                # Store VI counter values
                _state["vi_counters"] = {c.get("name", "zone"): c.get("count", 0) for c in data.get("counters", [])}
                for counter in data.get("counters", []):
                    if counter.get("count", 0) > 0:
                        _state["events"].insert(0, {
                            "type": "zone",
                            "text": f"{counter.get('name','zone')}: {counter['count']}",
                            "time": time.strftime("%I:%M:%S %p")
                        })

                _state["spark_data"].pop(0)
                _state["spark_data"].append(person_count)
                _state["events"] = _state["events"][:100]
                _state["camera_status"] = "Online"
            elif r.status_code == 401:
                _state["camera_status"] = "Token expired — refreshing"
                app.logger.warning("VI returned 401 — forcing token refresh")
                _do_refresh()
            else:
                _state["camera_status"] = f"API error ({r.status_code})"
        except requests.exceptions.ConnectionError:
            _state["camera_status"] = "VI unreachable"
        except Exception as e:
            _state["camera_status"] = f"Error"
            app.logger.error(f"Poll error: {e}")
        time.sleep(2)


@app.route("/")
def index():
    return render_template_string(DASHBOARD_HTML,
        camera_name=CAMERA_NAME,
        camera_id=_state.get("camera_id", ""),
    )

@app.route("/api/stats")
def stats():
    return jsonify(_state)

@app.route("/api/health")
def health():
    return jsonify({"status": "ok", "camera": _state["camera_status"]})


DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>GEOINT Booth — Live Perimeter Analytics</title>
<style>
*{box-sizing:border-box;font-family:"Segoe UI",system-ui,sans-serif;margin:0}
body{background:#0a0c14;color:#f5f6fa;height:100vh;overflow:hidden}
.dash{display:grid;grid-template-rows:auto auto 1fr auto;height:100vh;padding:1.2rem 2rem;gap:1rem}

/* Header */
.hdr{display:flex;justify-content:space-between;align-items:center}
.hdr h1{font-size:1.4rem;font-weight:600}.hdr h1 span{color:#00b4d8}
.status{display:flex;align-items:center;gap:.5rem;font-size:.9rem;color:#9ca4b3}
.dot{width:12px;height:12px;border-radius:50%;background:#ef4444;animation:pulse 2s infinite}
.dot.on{background:#22c55e}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.cam-badge{background:#1e2235;border:1px solid #2a3050;border-radius:8px;padding:.35rem .7rem;font-size:.8rem;color:#9ca4b3;display:inline-flex;align-items:center;gap:.4rem}
.cam-badge .cd{width:8px;height:8px;border-radius:50%;background:#22c55e}

/* Stats bar */
.stats-bar{display:grid;grid-template-columns:repeat(6,1fr);gap:.8rem}
.stat{background:#111320;border:1px solid #1e2235;border-radius:10px;padding:.7rem .8rem;text-align:center}
.stat .sv{font-size:2.4rem;font-weight:800;line-height:1;transition:all .3s}
.stat .sl{font-size:.65rem;color:#9ca4b3;text-transform:uppercase;letter-spacing:.06em;margin-top:.2rem}
.stat.c1 .sv{color:#00b4d8}
.stat.c2 .sv{color:#22c55e}
.stat.c3 .sv{color:#f59e0b}
.stat.c4 .sv{color:#a855f7}
.stat.c5 .sv{color:#3b82f6}
.stat.c6 .sv{color:#ef4444}

/* Main area */
.main-area{display:grid;grid-template-columns:1fr 380px;gap:1rem;min-height:0;overflow:hidden}

/* Event feed — hero */
.feed-panel{background:#111320;border:1px solid #1e2235;border-radius:12px;display:flex;flex-direction:column;overflow:hidden}
.feed-hdr{padding:.6rem 1rem;font-size:.75rem;color:#00b4d8;text-transform:uppercase;letter-spacing:.08em;font-weight:700;border-bottom:1px solid #1e2235;display:flex;align-items:center;gap:.5rem;flex-shrink:0}
.feed-hdr .fd{width:8px;height:8px;border-radius:50%;background:#ef4444;animation:pulse 1.5s infinite}
.feed-hdr .fd.on{background:#22c55e}
.feed-list{flex:1;overflow-y:auto;padding:.3rem .5rem;scroll-behavior:smooth}
.feed-list::-webkit-scrollbar{width:6px}
.feed-list::-webkit-scrollbar-track{background:transparent}
.feed-list::-webkit-scrollbar-thumb{background:#2c3247;border-radius:3px}
.fe{display:flex;align-items:flex-start;gap:.6rem;padding:.55rem .5rem;border-bottom:1px solid #0f111a;border-left:3px solid transparent;transition:background .15s}
.fe:hover{background:rgba(255,255,255,.02)}
.fe:last-child{border-bottom:none}
.fe.new{animation:slideIn .4s ease-out}
@keyframes slideIn{from{opacity:0;transform:translateX(-12px)}to{opacity:1;transform:translateX(0)}}
.fe.t-person{border-left-color:#00b4d8}
.fe.t-alert{border-left-color:#ef4444}
.fe.t-zone{border-left-color:#22c55e}
.fe .ficon{flex-shrink:0;width:28px;height:28px;border-radius:7px;display:flex;align-items:center;justify-content:center;font-size:.9rem}
.fe .ficon.person{background:#1e3a5f}
.fe .ficon.alert{background:#5f1e1e}
.fe .ficon.zone{background:#1e5f3a}
.fe .fbody{flex:1;min-width:0}
.fe .ftop{display:flex;align-items:center;gap:.5rem}
.fe .fbadge{font-size:.6rem;font-weight:700;text-transform:uppercase;padding:.15rem .4rem;border-radius:4px;flex-shrink:0}
.fe .fbadge.b-person{background:rgba(0,180,216,.15);color:#00b4d8}
.fe .fbadge.b-alert{background:rgba(239,68,68,.15);color:#ef4444}
.fe .fbadge.b-zone{background:rgba(34,197,94,.15);color:#22c55e}
.fe .ftext{font-size:.85rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.fe .ftime{font-size:.7rem;color:#6b7280;flex-shrink:0;margin-top:2px}
.feed-empty{padding:2rem;text-align:center;color:#4a5068;font-size:.9rem}

/* Right column */
.right-col{display:flex;flex-direction:column;gap:.8rem;min-height:0}
.chart-box{background:#111320;border:1px solid #1e2235;border-radius:12px;padding:1rem;flex-shrink:0}
.chart-box .tl{font-size:.7rem;color:#9ca4b3;text-transform:uppercase;letter-spacing:.06em;margin-bottom:.6rem}
.bars{display:flex;align-items:flex-end;gap:3px;height:70px}
.bar{flex:1;background:#00b4d8;border-radius:2px 2px 0 0;min-height:2px;opacity:.5;transition:height .5s}
.bar:last-child{opacity:1}

/* AI canvas */
.canvas-box{background:#000;border:1px solid #1e2235;border-radius:12px;flex:1;position:relative;overflow:hidden;min-height:180px}
.canvas-box canvas{display:block;width:100%;height:100%}
.hud{position:absolute;font-size:.65rem;font-family:"Cascadia Code","Fira Code",monospace;color:rgba(255,255,255,.6);padding:5px 8px;pointer-events:none}
.hud-tl{top:0;left:0;display:flex;gap:.6rem;align-items:center}
.hud-tr{top:0;right:0;color:rgba(0,180,216,.7)}
.hud-bl{bottom:0;left:0}
.hud-br{bottom:0;right:0}
.hud-live{color:#ef4444;font-weight:700;animation:pulse 1.5s infinite}
.hud-live.on{color:#22c55e}

/* Footer */
.ftr{display:flex;justify-content:space-between;align-items:center;font-size:.75rem;color:#4a5068}
.ftr .br span{color:#00b4d8;font-weight:600;font-size:.8rem}
</style></head><body>
<div class="dash">
  <div class="hdr">
    <h1>⬡ <span>GEOINT</span> Booth — Live Perimeter Intelligence</h1>
    <div class="status">
      <div class="cam-badge"><div class="cd" id="camDot"></div><span id="camLabel">{{ camera_name }}</span></div>
      <div class="dot" id="statusDot"></div>
      <span id="statusText">Connecting...</span>
    </div>
  </div>

  <div class="stats-bar">
    <div class="stat c1"><div class="sv" id="currentInFrame">0</div><div class="sl">In Frame Now</div></div>
    <div class="stat c2"><div class="sv" id="totalCount">0</div><div class="sl">Unique People</div></div>
    <div class="stat c3"><div class="sv" id="peakCount">0</div><div class="sl">Peak</div></div>
    <div class="stat c5"><div class="sv" id="zoneEntries">0</div><div class="sl">Zone Entries</div></div>
    <div class="stat c4"><div class="sv" id="alertCount">0</div><div class="sl">AI Alerts</div></div>
    <div class="stat c6"><div class="sv" id="uptime">0m</div><div class="sl">Uptime</div></div>
  </div>

  <div class="main-area">
    <div class="feed-panel">
      <div class="feed-hdr"><div class="fd" id="feedDot"></div>LIVE EVENT FEED — Azure Video Indexer</div>
      <div class="feed-list" id="feedList"><div class="feed-empty">Waiting for camera…</div></div>
    </div>
    <div class="right-col">
      <div class="chart-box">
        <div class="tl">Detections — Last 60 Seconds</div>
        <div class="bars" id="sparkline"></div>
      </div>
      <div class="canvas-box">
        <canvas id="aiCanvas"></canvas>
        <div class="hud hud-tl"><span class="hud-live" id="hudLive">● LIVE</span><span id="hudRes" style="color:rgba(255,255,255,.35)"></span></div>
        <div class="hud hud-tr">YOLOv8 + VI Arc</div>
        <div class="hud hud-bl" id="hudCam">{{ camera_name }}</div>
        <div class="hud hud-br" id="hudFps">-- fps</div>
      </div>
    </div>
  </div>

  <div class="ftr">
    <div class="br"><span>⬡ GEOINT on Azure Local</span> — Edge AI • Zero Cloud • Full Data Sovereignty</div>
    <div id="clock"></div>
  </div>
</div>
<script>
const t0=Date.now();
const canvas=document.getElementById('aiCanvas');
const ctx=canvas.getContext('2d');
let dets=[],scanY=0,isOn=false,lastPoll=0;
const icons={person:'👤',alert:'⚠️',zone:'📍'};

function resizeCanvas(){const r=canvas.parentElement.getBoundingClientRect();canvas.width=r.width*devicePixelRatio;canvas.height=r.height*devicePixelRatio;ctx.scale(devicePixelRatio,devicePixelRatio)}

function drawFrame(){
const w=canvas.width/devicePixelRatio,h=canvas.height/devicePixelRatio;
ctx.fillStyle='#080a12';ctx.fillRect(0,0,w,h);
ctx.strokeStyle='rgba(30,34,53,.5)';ctx.lineWidth=.5;
for(let x=0;x<w;x+=35){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,h);ctx.stroke()}
for(let y=0;y<h;y+=35){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(w,y);ctx.stroke()}
if(!isOn&&!dets.length){ctx.fillStyle='rgba(156,164,179,.25)';ctx.font='600 14px system-ui';ctx.textAlign='center';ctx.fillText('AWAITING CAMERA FEED',w/2,h/2-8);ctx.font='11px system-ui';ctx.fillText('Connect VI camera to see live AI detections',w/2,h/2+12);ctx.textAlign='start'}
dets.forEach(d=>{
const b=d.bbox||{};const bx=(b.x||0)*w,by=(b.y||0)*h,bw=(b.width||b.w||.08)*w,bh=(b.height||b.h||.2)*h;
const isPerson=(d.type||'').toLowerCase().includes('person');
const col=isPerson?'#00b4d8':'#f59e0b';const conf=d.confidence?(d.confidence*100).toFixed(0):'—';
ctx.shadowColor=col;ctx.shadowBlur=6;ctx.strokeStyle=col;ctx.lineWidth=2;ctx.strokeRect(bx,by,bw,bh);ctx.shadowBlur=0;
const c=8;ctx.lineWidth=3;ctx.strokeStyle=col;
ctx.beginPath();ctx.moveTo(bx,by+c);ctx.lineTo(bx,by);ctx.lineTo(bx+c,by);ctx.stroke();
ctx.beginPath();ctx.moveTo(bx+bw-c,by);ctx.lineTo(bx+bw,by);ctx.lineTo(bx+bw,by+c);ctx.stroke();
ctx.beginPath();ctx.moveTo(bx,by+bh-c);ctx.lineTo(bx,by+bh);ctx.lineTo(bx+c,by+bh);ctx.stroke();
ctx.beginPath();ctx.moveTo(bx+bw-c,by+bh);ctx.lineTo(bx+bw,by+bh);ctx.lineTo(bx+bw,by+bh-c);ctx.stroke();
const lbl=`${d.type||'object'} ${conf}%`;ctx.font='600 10px monospace';const tm=ctx.measureText(lbl);
ctx.fillStyle=col;ctx.fillRect(bx,by-14,tm.width+6,14);ctx.fillStyle='#000';ctx.fillText(lbl,bx+3,by-3);
if(d.id){ctx.font='9px monospace';ctx.fillStyle='rgba(255,255,255,.4)';ctx.fillText('ID:'+d.id,bx+3,by+bh-4)}
});
if(isOn){scanY=(scanY+1.5)%h;const g=ctx.createLinearGradient(0,scanY-15,0,scanY+15);g.addColorStop(0,'rgba(0,180,216,0)');g.addColorStop(.5,'rgba(0,180,216,.1)');g.addColorStop(1,'rgba(0,180,216,0)');ctx.fillStyle=g;ctx.fillRect(0,scanY-15,w,30)}
requestAnimationFrame(drawFrame)}

async function poll(){try{
const r=await fetch('/api/stats');const d=await r.json();
document.getElementById('totalCount').textContent=d.total_count;
document.getElementById('currentInFrame').textContent=d.current_in_frame;
document.getElementById('peakCount').textContent=d.peak_count;
document.getElementById('zoneEntries').textContent=d.zone_entries;
document.getElementById('alertCount').textContent=d.alert_count;

isOn=d.camera_status==='Online';
document.getElementById('statusDot').classList.toggle('on',isOn);
document.getElementById('camDot').style.background=isOn?'#22c55e':'#ef4444';
document.getElementById('statusText').textContent=isOn?'Live — Real-Time AI Detection':d.camera_status;
document.getElementById('hudLive').classList.toggle('on',isOn);
document.getElementById('feedDot').classList.toggle('on',isOn);
document.getElementById('hudRes').textContent=d.resolution||'';

dets=d.last_detections||[];

const now=Date.now();if(lastPoll){document.getElementById('hudFps').textContent=((1000/(now-lastPoll)).toFixed(0))+' fps'}lastPoll=now;

const mx=Math.max(...d.spark_data,1);
document.getElementById('sparkline').innerHTML=d.spark_data.map(v=>'<div class="bar" style="height:'+Math.max(4,(v/mx)*100)+'%"></div>').join('');

const evs=(d.events||[]).slice(0,25);
if(evs.length){
document.getElementById('feedList').innerHTML=evs.map((e,i)=>{
const t=e.type||'zone';
return '<div class="fe t-'+t+(i===0?' new':'')+'">'+
'<div class="ficon '+t+'">'+(icons[t]||'📌')+'</div>'+
'<div class="fbody"><div class="ftop">'+
'<span class="fbadge b-'+t+'">'+t.toUpperCase()+'</span>'+
'<span class="ftext">'+e.text+'</span>'+
'</div></div>'+
'<span class="ftime">'+e.time+'</span></div>'}).join('')}
else{document.getElementById('feedList').innerHTML='<div class="feed-empty">'+(isOn?'Monitoring — no events yet':'Waiting for camera…')+'</div>'}

const mins=Math.floor((Date.now()-t0)/60000);
document.getElementById('uptime').textContent=mins<60?mins+'m':Math.floor(mins/60)+'h'+mins%60+'m';
}catch(e){document.getElementById('statusText').textContent='Reconnecting...'}}

resizeCanvas();window.addEventListener('resize',resizeCanvas);requestAnimationFrame(drawFrame);
setInterval(poll,2000);poll();
setInterval(()=>{const n=new Date();document.getElementById('clock').textContent=n.toLocaleDateString('en-US',{weekday:'short',month:'short',day:'numeric'})+'  '+n.toLocaleTimeString('en-US',{hour:'2-digit',minute:'2-digit',second:'2-digit'})},1000);
</script></body></html>"""

if __name__ == "__main__":
    threading.Thread(target=poll_insights, daemon=True).start()
    threading.Thread(target=token_refresh_loop, daemon=True).start()
    discover_camera()
    app.run(host="0.0.0.0", port=8080)
