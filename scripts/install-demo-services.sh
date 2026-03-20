#!/usr/bin/env bash
set -euo pipefail

TARGET=${1:-}
if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <geo|globe|sensor|all>" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

install_service() {
  local src=$1
  local dest=$2
  local name=$3
  install -m 644 "$src" "$dest"
  systemctl daemon-reload
  systemctl enable --now "$name"
  systemctl status "$name" --no-pager
}

case "$TARGET" in
  geo)
    install_service "$REPO_ROOT/demo2-geo-platform/systemd/demo2-geoplatform.service" /etc/systemd/system/demo2-geoplatform.service demo2-geoplatform.service
    ;;
  globe)
    install_service "$REPO_ROOT/demo3-tactical-globe/systemd/demo3-globe.service" /etc/systemd/system/demo3-globe.service demo3-globe.service
    ;;
  sensor)
    install -m 644 "$REPO_ROOT/demo0-iot-backbone/sensor-simulator/systemd/sensor-simulator.env" /opt/geoint/demo0-iot-backbone/sensor-simulator/systemd/sensor-simulator.env
    install_service "$REPO_ROOT/demo0-iot-backbone/sensor-simulator/systemd/sensor-simulator.service" /etc/systemd/system/sensor-simulator.service sensor-simulator.service
    ;;
  all)
    "$0" geo
    "$0" globe
    "$0" sensor
    ;;
  *)
    echo "Unknown target: $TARGET" >&2
    exit 1
    ;;
esac
