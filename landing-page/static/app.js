const servicesEl = document.getElementById("services");
const clockEl = document.getElementById("clock");

function formatTime(date) {
  return date.toISOString().split("T")[1].slice(0, 8);
}

/* ─── Service health tiles ─── */

async function fetchHealth() {
  try {
    const res = await fetch("/api/health");
    const data = await res.json();
    renderCards(data.services || []);
  } catch (err) {
    console.error("Health check failed", err);
  }
}

function renderCards(services) {
  servicesEl.innerHTML = "";
  services.forEach((svc) => {
    const card = document.createElement("article");
    card.className = "card";

    const badgeClass = svc.healthy ? "badge up" : "badge down";
    const badgeText = svc.healthy ? "Online" : "Offline";
    const latency = svc.latency ? `${svc.latency.toFixed(0)} ms` : "--";

    card.innerHTML = `
      <div>
        <h2>${svc.name}</h2>
        <p>${svc.description || ""}</p>
      </div>
      <div>
        <div class="badge ${badgeClass}">${badgeText} · ${latency}</div>
        <div class="actions">
          <a href="${svc.url}" target="_blank" rel="noopener">Open</a>
        </div>
      </div>
    `;
    servicesEl.appendChild(card);
  });
}

/* ─── AI Detection Canvas ─── */

const canvas = document.getElementById("aiCanvas");
const ctx = canvas.getContext("2d");
let detections = [];
let frameW = 1920;
let frameH = 1080;
let scanY = 0;
let isOnline = false;

function resizeCanvas() {
  const rect = canvas.parentElement.getBoundingClientRect();
  canvas.width = rect.width * devicePixelRatio;
  canvas.height = rect.height * devicePixelRatio;
  ctx.scale(devicePixelRatio, devicePixelRatio);
}

function drawFrame() {
  const w = canvas.width / devicePixelRatio;
  const h = canvas.height / devicePixelRatio;

  // Dark background with subtle noise
  ctx.fillStyle = "#080a12";
  ctx.fillRect(0, 0, w, h);

  // Grid overlay
  ctx.strokeStyle = "rgba(30, 34, 53, 0.6)";
  ctx.lineWidth = 0.5;
  const gridSize = 40;
  for (let x = 0; x < w; x += gridSize) {
    ctx.beginPath();
    ctx.moveTo(x, 0);
    ctx.lineTo(x, h);
    ctx.stroke();
  }
  for (let y = 0; y < h; y += gridSize) {
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
  }

  if (!isOnline && detections.length === 0) {
    // Offline state
    ctx.fillStyle = "rgba(156, 164, 179, 0.3)";
    ctx.font = "600 16px 'Segoe UI', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.fillText("AWAITING CAMERA FEED", w / 2, h / 2 - 10);
    ctx.font = "12px 'Segoe UI', system-ui, sans-serif";
    ctx.fillText("Connect VI camera to see live AI detections", w / 2, h / 2 + 14);
    ctx.textAlign = "start";
  }

  // Draw detection bounding boxes
  detections.forEach((d, i) => {
    const bbox = d.bbox || {};
    const bx = (bbox.x || 0) * w;
    const by = (bbox.y || 0) * h;
    const bw = (bbox.width || bbox.w || 0.08) * w;
    const bh = (bbox.height || bbox.h || 0.2) * h;

    const isPerson = (d.type || "").toLowerCase().includes("person");
    const color = isPerson ? "#00b4d8" : "#f59e0b";
    const conf = d.confidence ? (d.confidence * 100).toFixed(0) : "—";

    // Box glow
    ctx.shadowColor = color;
    ctx.shadowBlur = 8;
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.strokeRect(bx, by, bw, bh);
    ctx.shadowBlur = 0;

    // Corner brackets
    const c = 10;
    ctx.lineWidth = 3;
    ctx.strokeStyle = color;
    // top-left
    ctx.beginPath(); ctx.moveTo(bx, by + c); ctx.lineTo(bx, by); ctx.lineTo(bx + c, by); ctx.stroke();
    // top-right
    ctx.beginPath(); ctx.moveTo(bx + bw - c, by); ctx.lineTo(bx + bw, by); ctx.lineTo(bx + bw, by + c); ctx.stroke();
    // bottom-left
    ctx.beginPath(); ctx.moveTo(bx, by + bh - c); ctx.lineTo(bx, by + bh); ctx.lineTo(bx + c, by + bh); ctx.stroke();
    // bottom-right
    ctx.beginPath(); ctx.moveTo(bx + bw - c, by + bh); ctx.lineTo(bx + bw, by + bh); ctx.lineTo(bx + bw, by + bh - c); ctx.stroke();

    // Label
    const label = `${d.type || "object"} ${conf}%`;
    ctx.font = "600 11px 'Cascadia Code', 'Fira Code', monospace";
    const tm = ctx.measureText(label);
    const lx = bx;
    const ly = by - 4;
    ctx.fillStyle = color;
    ctx.fillRect(lx, ly - 13, tm.width + 8, 16);
    ctx.fillStyle = "#000";
    ctx.fillText(label, lx + 4, ly - 1);

    // Track ID
    if (d.id) {
      ctx.font = "10px 'Cascadia Code', monospace";
      ctx.fillStyle = "rgba(255,255,255,0.5)";
      ctx.fillText(`ID: ${d.id}`, bx + 4, by + bh - 6);
    }
  });

  // Scanning line (shows AI is processing)
  if (isOnline) {
    scanY = (scanY + 1.5) % h;
    const grad = ctx.createLinearGradient(0, scanY - 20, 0, scanY + 20);
    grad.addColorStop(0, "rgba(0, 180, 216, 0)");
    grad.addColorStop(0.5, "rgba(0, 180, 216, 0.12)");
    grad.addColorStop(1, "rgba(0, 180, 216, 0)");
    ctx.fillStyle = grad;
    ctx.fillRect(0, scanY - 20, w, 40);
  }

  requestAnimationFrame(drawFrame);
}

/* ─── Live feed data (SSE with polling fallback) ─── */

const lfDot = document.getElementById("lfDot");
const lfStatus = document.getElementById("lfStatus");
const lfCamName = document.getElementById("lfCamName");
const lfPeople = document.getElementById("lfPeople");
const lfInFrame = document.getElementById("lfInFrame");
const lfPeak = document.getElementById("lfPeak");
const lfAlerts = document.getElementById("lfAlerts");
const lfSpark = document.getElementById("lfSpark");
const lfEvents = document.getElementById("lfEvents");
const lfPanel = document.getElementById("liveFeedPanel");
const hudLive = document.getElementById("hudLive");
const hudRes = document.getElementById("hudRes");
const hudCam = document.getElementById("hudCam");
const hudFps = document.getElementById("hudFps");

const eventIcons = { person: "\u{1F464}", alert: "\u26A0\uFE0F", zone: "\u{1F4CD}", vehicle: "\u{1F697}", object: "\u{1F4E6}" };

const badgeClasses = {
  person: "badge-person",
  vehicle: "badge-vehicle",
  object: "badge-object",
  alert: "badge-alert",
  zone: "badge-zone",
};

const evClasses = {
  person: "ev-person",
  vehicle: "ev-vehicle",
  object: "ev-object",
  alert: "ev-alert",
  zone: "ev-zone",
};
let sseActive = false;
let lastPollTime = 0;

function applyFeedData(d) {
  if (d.error) {
    setFeedOffline();
    return;
  }

  isOnline = d.camera_status === "Online";
  lfDot.classList.toggle("on", isOnline);
  hudLive.classList.toggle("on", isOnline);
  lfPanel.classList.toggle("offline", !isOnline);
  lfStatus.textContent = isOnline
    ? "Live \u2014 Real-Time AI Detection"
    : d.camera_status || "Offline";
  lfCamName.textContent = d.camera_name || "booth-cam";
  hudCam.textContent = d.camera_name || "geoint-booth-cam";
  hudRes.textContent = d.resolution || "";

  lfPeople.textContent = d.total_count ?? 0;
  lfInFrame.textContent = d.current_in_frame ?? 0;
  lfPeak.textContent = d.peak_count ?? 0;
  lfAlerts.textContent = d.alert_count ?? 0;

  // Update detections for canvas
  detections = d.last_detections || [];
  frameW = d.frame_width || 1920;
  frameH = d.frame_height || 1080;

  // FPS indicator
  const now = Date.now();
  if (lastPollTime) {
    const fps = (1000 / (now - lastPollTime)).toFixed(0);
    hudFps.textContent = `${fps} fps`;
  }
  lastPollTime = now;

  // Sparkline
  const spark = d.spark_data || [];
  const mx = Math.max(...spark, 1);
  lfSpark.innerHTML = spark
    .map(
      (v) =>
        `<div class="lf-bar" style="height:${Math.max(4, (v / mx) * 100)}%"></div>`
    )
    .join("");

  renderEvents(d.events || [], isOnline);
}

function renderEvents(events, online) {
  const items = events.slice(0, 25);
  if (items.length) {
    lfEvents.innerHTML = items
      .map((e, i) => {
        const evType = (e.type || "object").toLowerCase();
        const rowClass = evClasses[evType] || "ev-object";
        const icon = eventIcons[evType] || "\u{1F4CC}";
        const badge = badgeClasses[evType] || "badge-object";
        const badgeLabel = evType.toUpperCase();

        const confPct = e.confidence != null
          ? `${(typeof e.confidence === "number" && e.confidence <= 1 ? e.confidence * 100 : e.confidence).toFixed(0)}%`
          : "";

        // Build tracking ID string
        let metaParts = [];
        if (e.count != null) metaParts.push(`${e.count} in frame`);
        if (e.ids && e.ids.length) metaParts.push(`ID: ${e.ids.join(", ")}`);
        else if (e.id) metaParts.push(`ID: ${e.id}`);
        const metaStr = metaParts.length ? metaParts.join(" · ") : "";

        return (
          `<div class="lf-ev ${rowClass}${i === 0 ? " lf-ev-new" : ""}">` +
            `<span class="lf-ev-icon">${icon}</span>` +
            `<div class="lf-ev-body">` +
              `<div class="lf-ev-top">` +
                `<span class="lf-ev-badge ${badge}">${badgeLabel}${confPct ? " " + confPct : ""}</span>` +
                `<span class="lf-ev-text">${e.text}</span>` +
              `</div>` +
              (metaStr ? `<div class="lf-ev-meta">${metaStr}</div>` : "") +
            `</div>` +
            `<span class="lf-ev-time">${e.time}</span>` +
          `</div>`
        );
      })
      .join("");
  } else {
    lfEvents.innerHTML = `<div class="lf-events-empty">${
      online ? "Monitoring \u2014 no events yet" : "Waiting for camera\u2026"
    }</div>`;
  }
}

function setFeedOffline() {
  isOnline = false;
  detections = [];
  lfDot.classList.remove("on");
  hudLive.classList.remove("on");
  lfPanel.classList.add("offline");
  lfStatus.textContent = "Feed unavailable";
  lfEvents.innerHTML =
    '<div class="lf-events-empty">Booth camera offline</div>';
}

/* SSE with auto-reconnect */
function connectSSE() {
  const es = new EventSource("/api/live-feed/stream");
  es.addEventListener("stats", (e) => {
    sseActive = true;
    try { applyFeedData(JSON.parse(e.data)); } catch {}
  });
  es.addEventListener("events", (e) => {
    try {
      const ne = JSON.parse(e.data);
      if (ne.length) renderEvents(ne, true);
    } catch {}
  });
  es.onerror = () => {
    sseActive = false;
    es.close();
    setTimeout(connectSSE, 5000);
  };
}

/* Polling fallback */
async function fetchLiveFeed() {
  if (sseActive) return;
  try {
    const res = await fetch("/api/live-feed");
    const d = await res.json();
    applyFeedData(d);
  } catch {
    setFeedOffline();
  }
}

function tickClock() {
  clockEl.textContent = formatTime(new Date());
}

/* ── Init ── */
resizeCanvas();
window.addEventListener("resize", resizeCanvas);
requestAnimationFrame(drawFrame);

fetchHealth();
connectSSE();
fetchLiveFeed();
setInterval(fetchHealth, 10000);
setInterval(fetchLiveFeed, 3000);
setInterval(tickClock, 1000);
tickClock();
