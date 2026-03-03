# Build context: demo3-tactical-globe/ (parent of server/)
# docker build -f server/Dockerfile -t tactical-globe .
FROM python:3.12-slim
WORKDIR /app

# Create non-root user
RUN adduser --disabled-password --gecos '' appuser

# Install Python dependencies
COPY server/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy server source
COPY server/server.py ./server.py

# Copy CesiumJS client (served as static files at /app/public)
COPY client /app/public

RUN chown -R appuser:appuser /app
USER appuser

EXPOSE 3000
ENV STATIC_DIR=/app/public
CMD ["python", "server.py"]
