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
.dash{display:grid;grid-template-rows:auto 1fr auto;height:100vh;padding:1.5rem 2.5rem;gap:1.5rem}
.hdr{display:flex;justify-content:space-between;align-items:center}
.hdr h1{font-size:1.5rem;font-weight:600}.hdr h1 span{color:#00b4d8}
.status{display:flex;align-items:center;gap:.5rem;font-size:.95rem;color:#9ca4b3}
.dot{width:12px;height:12px;border-radius:50%;background:#ef4444;animation:p 2s infinite}
.dot.on{background:#22c55e}
@keyframes p{0%,100%{opacity:1}50%{opacity:.4}}
.main{display:grid;grid-template-columns:1fr 1fr 1fr;gap:1.5rem;min-height:0}
.big{background:linear-gradient(135deg,#111320,#151830);border:1px solid #1e2235;border-radius:16px;padding:2.5rem;text-align:center;display:flex;flex-direction:column;justify-content:center}
.big .label{font-size:1rem;color:#9ca4b3;text-transform:uppercase;letter-spacing:.12em;margin-bottom:.8rem}
.big .val{font-size:8rem;font-weight:800;line-height:1;transition:all .3s}
.big .sub{font-size:.9rem;color:#6b7280;margin-top:.8rem}
.big.cyan .val{color:#00b4d8}
.big.green .val{color:#22c55e}
.big.amber .val{color:#f59e0b}
.row2{display:grid;grid-template-columns:repeat(4,1fr);gap:1rem}
.card{background:#111320;border:1px solid #1e2235;border-radius:12px;padding:1.5rem;text-align:center}
.card .cv{font-size:3rem;font-weight:700;transition:all .3s}
.card .cl{font-size:.75rem;color:#9ca4b3;text-transform:uppercase;letter-spacing:.06em;margin-top:.4rem}
.card.blue .cv{color:#3b82f6}.card.purple .cv{color:#a855f7}.card.green .cv{color:#22c55e}.card.amber .cv{color:#f59e0b}
.bottom{display:grid;grid-template-columns:1fr 350px;gap:1.5rem;min-height:0}
.chart{background:#111320;border:1px solid #1e2235;border-radius:12px;padding:1.2rem;display:flex;flex-direction:column}
.chart .tl{font-size:.8rem;color:#9ca4b3;text-transform:uppercase;letter-spacing:.06em;margin-bottom:.8rem}
.bars{display:flex;align-items:flex-end;gap:4px;flex:1;min-height:80px}
.bar{flex:1;background:#00b4d8;border-radius:3px 3px 0 0;min-height:3px;opacity:.6;transition:height .5s}
.bar:last-child{opacity:1}
.feed{background:#111320;border:1px solid #1e2235;border-radius:12px;display:flex;flex-direction:column;overflow:hidden}
.feed .fh{padding:.8rem 1rem;font-size:.8rem;color:#9ca4b3;text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid #1e2235}
.fl{flex:1;overflow-y:auto;padding:.4rem .6rem}
.fi{display:flex;align-items:center;gap:.6rem;padding:.5rem .4rem;border-bottom:1px solid #0f111a;font-size:.85rem}
.fi .ic{width:26px;height:26px;border-radius:6px;display:flex;align-items:center;justify-content:center;font-size:.85rem;flex-shrink:0}
.fi .ic.person{background:#1e3a5f}.fi .ic.alert{background:#5f1e1e}.fi .ic.zone{background:#1e5f3a}
.fi .tx{flex:1}.fi .tm{color:#6b7280;font-size:.7rem;flex-shrink:0}
.ftr{display:flex;justify-content:space-between;align-items:center;font-size:.8rem;color:#4a5068}
.ftr .br span{color:#00b4d8;font-weight:600;font-size:.85rem}
.cam-badge{background:#1e2235;border:1px solid #2a3050;border-radius:8px;padding:.4rem .8rem;font-size:.8rem;color:#9ca4b3;display:inline-flex;align-items:center;gap:.4rem}
.cam-badge .cd{width:8px;height:8px;border-radius:50%;background:#22c55e}
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
  <div style="display:flex;flex-direction:column;gap:1.5rem;min-height:0">
    <div class="main">
      <div class="big cyan">
        <div class="label">People Detected Today</div>
        <div class="val" id="totalCount">0</div>
        <div class="sub" id="camStatus">Connecting to camera...</div>
      </div>
      <div class="big green">
        <div class="label">In Frame Right Now</div>
        <div class="val" id="currentInFrame">0</div>
        <div class="sub">Real-time AI detection</div>
      </div>
      <div class="big amber">
        <div class="label">Peak Concurrent</div>
        <div class="val" id="peakCount">0</div>
        <div class="sub">Highest count today</div>
      </div>
    </div>
    <div class="row2">
      <div class="card blue"><div class="cv" id="zoneEntries">0</div><div class="cl">Zone Entries</div></div>
      <div class="card purple"><div class="cv" id="alertCount">0</div><div class="cl">AI Alerts</div></div>
      <div class="card green"><div class="cv" id="resolution">—</div><div class="cl">Resolution</div></div>
      <div class="card amber"><div class="cv" id="uptime">0m</div><div class="cl">Uptime</div></div>
    </div>
    <div class="bottom">
      <div class="chart">
        <div class="tl">People Detected — Last 60 Seconds</div>
        <div class="bars" id="sparkline"></div>
      </div>
      <div class="feed">
        <div class="fh">Live Event Feed</div>
        <div class="fl" id="feedList"></div>
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
async function poll(){try{const r=await fetch('/api/stats');const d=await r.json();
document.getElementById('totalCount').textContent=d.total_count;
document.getElementById('currentInFrame').textContent=d.current_in_frame;
document.getElementById('peakCount').textContent=d.peak_count;
document.getElementById('zoneEntries').textContent=d.zone_entries;
document.getElementById('alertCount').textContent=d.alert_count;
document.getElementById('resolution').textContent=d.resolution||'—';
document.getElementById('camStatus').textContent=d.camera_status+(d.camera_status==='Online'?' • 1920×1080 • 30fps':'');
const on=d.camera_status==='Online';
document.getElementById('statusDot').classList.toggle('on',on);
document.getElementById('camDot').style.background=on?'#22c55e':'#ef4444';
document.getElementById('statusText').textContent=on?'Live — Real-Time AI Detection':d.camera_status;
const mx=Math.max(...d.spark_data,1);
document.getElementById('sparkline').innerHTML=d.spark_data.map(v=>'<div class="bar" style="height:'+Math.max(4,(v/mx)*100)+'%"></div>').join('');
const ic={person:'👤',alert:'⚠️',zone:'📍'};
document.getElementById('feedList').innerHTML=(d.events||[]).slice(0,12).map(e=>'<div class="fi"><div class="ic '+e.type+'">'+(ic[e.type]||'📌')+'</div><div class="tx">'+e.text+'</div><div class="tm">'+e.time+'</div></div>').join('')||(on?'<div style="padding:1rem;color:#4a5068;text-align:center">Monitoring — no events yet</div>':'');
const mins=Math.floor((Date.now()-t0)/60000);
document.getElementById('uptime').textContent=mins<60?mins+'m':Math.floor(mins/60)+'h'+mins%60+'m';
}catch(e){document.getElementById('statusText').textContent='Reconnecting...';}}
setInterval(poll,2000);poll();
setInterval(()=>{const n=new Date();document.getElementById('clock').textContent=n.toLocaleDateString('en-US',{weekday:'short',month:'short',day:'numeric'})+'  '+n.toLocaleTimeString('en-US',{hour:'2-digit',minute:'2-digit',second:'2-digit'});},1000);
</script></body></html>"""

if __name__ == "__main__":
    threading.Thread(target=poll_insights, daemon=True).start()
    threading.Thread(target=token_refresh_loop, daemon=True).start()
    discover_camera()
    app.run(host="0.0.0.0", port=8080)
