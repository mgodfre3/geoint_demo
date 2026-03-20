const servicesEl = document.getElementById("services");
const clockEl = document.getElementById("clock");

function formatTime(date) {
  return date.toISOString().split("T")[1].slice(0, 8);
}

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

function tickClock() {
  clockEl.textContent = formatTime(new Date());
}

fetchHealth();
setInterval(fetchHealth, 10000);
setInterval(tickClock, 1000);
tickClock();
