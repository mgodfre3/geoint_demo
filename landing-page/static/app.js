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

/* ─── Live feed panel ─── */

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

async function fetchLiveFeed() {
  try {
    const res = await fetch("/api/live-feed");
    const d = await res.json();
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
    const events = (d.events || []).slice(0, 8);
    if (events.length) {
      lfEvents.innerHTML = events
        .map(
          (e) =>
            `<div class="lf-ev"><span class="lf-ev-icon">${eventIcons[e.type] || "📌"}</span><span class="lf-ev-text">${e.text}</span><span class="lf-ev-time">${e.time}</span></div>`
        )
        .join("");
    } else {
      lfEvents.innerHTML = `<div class="lf-events-empty">${online ? "Monitoring — no events yet" : "Waiting for camera…"}</div>`;
    }
  } catch {
    setFeedOffline();
  }
}

function setFeedOffline() {
  lfDot.classList.remove("on");
  lfPanel.classList.add("offline");
  lfStatus.textContent = "Feed unavailable";
  lfEvents.innerHTML =
    '<div class="lf-events-empty">Booth camera offline</div>';
}

function tickClock() {
  clockEl.textContent = formatTime(new Date());
}

fetchHealth();
fetchLiveFeed();
setInterval(fetchHealth, 10000);
setInterval(fetchLiveFeed, 2000);
setInterval(tickClock, 1000);
tickClock();
