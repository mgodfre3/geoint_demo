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

/* ─── Live feed panel (SSE with polling fallback) ─── */

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

const eventIcons = { person: "👤", alert: "⚠️", zone: "📍" };
let sseActive = false;

function applyFeedData(d) {
  if (d.error) {
    setFeedOffline();
    return;
  }

  const online = d.camera_status === "Online";
  lfDot.classList.toggle("on", online);
  lfPanel.classList.toggle("offline", !online);
  lfStatus.textContent = online
    ? "Live — Real-Time AI Detection"
    : d.camera_status || "Offline";
  lfCamName.textContent = d.camera_name || "booth-cam";

  lfPeople.textContent = d.total_count ?? 0;
  lfInFrame.textContent = d.current_in_frame ?? 0;
  lfPeak.textContent = d.peak_count ?? 0;
  lfAlerts.textContent = d.alert_count ?? 0;

  // Sparkline
  const spark = d.spark_data || [];
  const mx = Math.max(...spark, 1);
  lfSpark.innerHTML = spark
    .map(
      (v) =>
        `<div class="lf-bar" style="height:${Math.max(4, (v / mx) * 100)}%"></div>`
    )
    .join("");

  // Events
  renderEvents(d.events || [], online);
}

function renderEvents(events, online) {
  const items = events.slice(0, 12);
  if (items.length) {
    lfEvents.innerHTML = items
      .map(
        (e, i) =>
          `<div class="lf-ev${i === 0 ? " lf-ev-new" : ""}">` +
          `<span class="lf-ev-icon">${eventIcons[e.type] || "📌"}</span>` +
          `<span class="lf-ev-text">${e.text}</span>` +
          `<span class="lf-ev-time">${e.time}</span></div>`
      )
      .join("");
  } else {
    lfEvents.innerHTML = `<div class="lf-events-empty">${
      online ? "Monitoring — no events yet" : "Waiting for camera…"
    }</div>`;
  }
}

function setFeedOffline() {
  lfDot.classList.remove("on");
  lfPanel.classList.add("offline");
  lfStatus.textContent = "Feed unavailable";
  lfEvents.innerHTML =
    '<div class="lf-events-empty">Booth camera offline</div>';
}

/* SSE connection with auto-reconnect */
function connectSSE() {
  const es = new EventSource("/api/live-feed/stream");
  es.addEventListener("stats", (e) => {
    sseActive = true;
    try {
      applyFeedData(JSON.parse(e.data));
    } catch {}
  });
  es.addEventListener("events", (e) => {
    try {
      const newEvents = JSON.parse(e.data);
      if (newEvents.length) renderEvents(newEvents, true);
    } catch {}
  });
  es.onerror = () => {
    sseActive = false;
    es.close();
    setTimeout(connectSSE, 5000);
  };
}

/* Polling fallback — only runs when SSE is down */
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

fetchHealth();
connectSSE();
fetchLiveFeed();
setInterval(fetchHealth, 10000);
setInterval(fetchLiveFeed, 3000);
setInterval(tickClock, 1000);
tickClock();
