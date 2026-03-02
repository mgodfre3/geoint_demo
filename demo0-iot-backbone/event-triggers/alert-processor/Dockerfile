# syntax=docker/dockerfile:1
# ────────────────────────────────────────────────────────────────
# GEOINT Demo — Alert Processor
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
RUN addgroup --system processor && adduser --system --ingroup processor processor

WORKDIR /app

# Copy installed packages from builder stage
COPY --from=builder /install /usr/local

# Copy application source
COPY processor.py .

USER processor

ENV VISION_PIPELINE_URL=http://demo1-vision-service:8080/jobs \
    ALERT_PROCESSOR_PORT=8080

EXPOSE 8080

CMD ["python", "processor.py"]
