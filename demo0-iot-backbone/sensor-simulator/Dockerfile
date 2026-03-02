# syntax=docker/dockerfile:1
# ────────────────────────────────────────────────────────────────
# GEOINT Demo — Sensor Simulator
# Multi-stage build: slim runtime image, non-root user.
# ────────────────────────────────────────────────────────────────

# ── Stage 1: dependency builder ──────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Stage 2: runtime image ───────────────────────────────────────
FROM python:3.11-slim AS runtime

# Non-root user for security
RUN addgroup --system simulator && adduser --system --ingroup simulator simulator

WORKDIR /app

# Copy installed packages from builder stage
COPY --from=builder /install /usr/local

# Copy application source
COPY simulator.py .
COPY scenarios/ scenarios/

USER simulator

ENV MQTT_HOST=localhost \
    MQTT_PORT=1883 \
    MQTT_USERNAME=geoint-demo \
    MQTT_PASSWORD="" \
    SCENARIO_FILE=scenarios/base_scenario.json \
    LOOP=true

CMD ["python", "simulator.py"]
