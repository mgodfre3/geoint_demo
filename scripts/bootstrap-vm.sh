#!/bin/bash
# ============================================================
# GEOINT Demo — VM Bootstrap Script
# ============================================================
# Run this on each Azure Local VM after provisioning.
# Usage:
#   ./bootstrap-vm.sh geoserver   # for den-geoserver VM (Demo 2)
#   ./bootstrap-vm.sh globe       # for den-globe VM (Demo 3)
# ============================================================

set -euo pipefail

ROLE="${1:-}"
REPO_URL="${2:-https://github.com/mgodfre3/geoint_demo.git}"
BRANCH="${3:-main}"

if [[ -z "$ROLE" ]]; then
    echo "Usage: $0 <geoserver|globe> [repo-url] [branch]"
    exit 1
fi

echo "=== GEOINT VM Bootstrap: $ROLE ==="

# --- Install Docker ---
if ! command -v docker &>/dev/null; then
    echo "[1/3] Installing Docker..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo usermod -aG docker "$USER"
    echo "  Docker installed. You may need to log out/in for group changes."
else
    echo "[1/3] Docker already installed"
fi

# --- Clone repo ---
DEMO_DIR="/opt/geoint-demo"
if [[ ! -d "$DEMO_DIR" ]]; then
    echo "[2/3] Cloning repository..."
    sudo git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$DEMO_DIR"
    sudo chown -R "$USER:$USER" "$DEMO_DIR"
else
    echo "[2/3] Repository already cloned, pulling latest..."
    cd "$DEMO_DIR" && git pull origin "$BRANCH"
fi

# --- Start services ---
echo "[3/3] Starting services..."
case "$ROLE" in
    geoserver)
        cd "$DEMO_DIR/demo2-geo-platform"
        echo "  Starting GeoServer + PostGIS + TileServer + Frontend..."
        sudo docker compose up -d --build
        echo ""
        echo "=== Demo 2 (Geo Platform) is starting ==="
        echo "  Frontend:   http://$(hostname -I | awk '{print $1}'):8083"
        echo "  GeoServer:  http://$(hostname -I | awk '{print $1}'):8084/geoserver/web/"
        echo "  TileServer: http://$(hostname -I | awk '{print $1}'):8085"
        ;;
    globe)
        cd "$DEMO_DIR/demo3-tactical-globe"
        echo "  Starting Tactical Globe server..."
        sudo docker compose up -d --build
        echo ""
        echo "=== Demo 3 (Tactical Globe) is starting ==="
        echo "  Globe UI: http://$(hostname -I | awk '{print $1}'):8085"
        ;;
    *)
        echo "ERROR: Unknown role '$ROLE'. Use 'geoserver' or 'globe'."
        exit 1
        ;;
esac

echo ""
echo "Done! Check status with: sudo docker compose ps"
