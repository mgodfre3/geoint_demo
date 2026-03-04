"""PostGIS ingest worker for MQTT sensor telemetry.

Subscribes to the Azure IoT Operations pipeline topic and persists each
message into the `sensor_telemetry` PostGIS table.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Optional
from uuid import uuid4

import paho.mqtt.client as mqtt
import psycopg
from psycopg.types.json import Jsonb
from pythonjsonlogger import jsonlogger

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
MQTT_HOST = os.environ.get("MQTT_HOST", "localhost")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
MQTT_USERNAME = os.environ.get("MQTT_USERNAME", "")
MQTT_PASSWORD = os.environ.get("MQTT_PASSWORD", "")
MQTT_TOPIC = os.environ.get("MQTT_TOPIC", "geoint/pipelines/sensor-telemetry")
MQTT_CLIENT_ID = os.environ.get("MQTT_CLIENT_ID", f"postgis-ingest-{uuid4().hex[:8]}")

POSTGRES_HOST = os.environ.get("POSTGRES_HOST", "postgis")
POSTGRES_PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
POSTGRES_DB = os.environ.get("POSTGRES_DB", "geoint")
POSTGRES_USER = os.environ.get("POSTGRES_USER", "geoint")
POSTGRES_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "geoint_demo_2026")
POSTGRES_CONNECT_RETRY_SECONDS = int(os.environ.get("POSTGRES_CONNECT_RETRY_SECONDS", "5"))

INSERT_SQL = """
INSERT INTO sensor_telemetry (
    sensor_id,
    sensor_type,
    grid_ref,
    recorded_at,
    lat,
    lon,
    geom,
    is_alert,
    reading
)
VALUES (
    %(sensor_id)s,
    %(sensor_type)s,
    %(grid_ref)s,
    %(recorded_at)s,
    %(lat)s,
    %(lon)s,
    ST_GeomFromEWKT(%(geom)s),
    %(is_alert)s,
    %(reading)s
);
"""


def configure_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    formatter = jsonlogger.JsonFormatter("%(asctime)s %(levelname)s %(message)s")
    handler.setFormatter(formatter)

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(LOG_LEVEL)


@dataclass
class SensorRecord:
    sensor_id: str
    sensor_type: str
    grid_ref: Optional[str]
    recorded_at: Optional[datetime]
    lat: Optional[float]
    lon: Optional[float]
    geom_ewkt: Optional[str]
    is_alert: bool
    reading: Optional[dict[str, Any]]

    @property
    def as_params(self) -> dict[str, Any]:
        return {
            "sensor_id": self.sensor_id,
            "sensor_type": self.sensor_type,
            "grid_ref": self.grid_ref,
            "recorded_at": self.recorded_at,
            "lat": self.lat,
            "lon": self.lon,
            "geom": self.geom_ewkt,
            "is_alert": self.is_alert,
            "reading": Jsonb(self.reading) if self.reading is not None else None,
        }


class PostgisWriter:
    def __init__(self) -> None:
        self._conn: Optional[psycopg.Connection] = None

    def connect(self) -> None:
        dsn = (
            f"host={POSTGRES_HOST} port={POSTGRES_PORT} dbname={POSTGRES_DB} "
            f"user={POSTGRES_USER} password={POSTGRES_PASSWORD}"
        )
        while True:
            try:
                self._conn = psycopg.connect(dsn, autocommit=True)
                logging.info("Connected to PostGIS", host=POSTGRES_HOST, db=POSTGRES_DB)
                return
            except psycopg.OperationalError as exc:
                logging.error(
                    "PostGIS connection failed, retrying",
                    error=str(exc),
                    host=POSTGRES_HOST,
                )
                time.sleep(POSTGRES_CONNECT_RETRY_SECONDS)

    def close(self) -> None:
        if self._conn and not self._conn.closed:
            self._conn.close()
            logging.info("PostGIS connection closed")

    def _ensure_connection(self) -> None:
        if self._conn is None or self._conn.closed:
            self.connect()

    def insert(self, record: SensorRecord) -> None:
        self._ensure_connection()
        assert self._conn is not None  # For mypy/static analyzers
        try:
            with self._conn.cursor() as cur:
                cur.execute(INSERT_SQL, record.as_params)
        except psycopg.Error as exc:
            logging.error("Insert failed, reconnecting", error=str(exc))
            self.connect()
            with self._conn.cursor() as cur:
                cur.execute(INSERT_SQL, record.as_params)


def parse_float(value: Any) -> Optional[float]:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_timestamp(raw: Any) -> Optional[datetime]:
    if not raw:
        return None
    if isinstance(raw, datetime):
        return raw
    if isinstance(raw, (int, float)):
        return datetime.fromtimestamp(float(raw))
    if isinstance(raw, str):
        normalized = raw.strip().replace("Z", "+00:00")
        try:
            return datetime.fromisoformat(normalized)
        except ValueError:
            return None
    return None


def coerce_json(value: Any) -> Optional[dict[str, Any]]:
    if value is None:
        return None
    if isinstance(value, dict):
        return value
    if isinstance(value, str) and value.strip():
        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {"value": parsed}
        except json.JSONDecodeError:
            return {"raw": value}
    return None


def build_record(payload: bytes) -> SensorRecord:
    try:
        message = json.loads(payload.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid JSON payload: {exc}") from exc

    sensor_id = message.get("sensor_id")
    sensor_type = message.get("sensor_type")
    if not sensor_id or not sensor_type:
        raise ValueError("sensor_id and sensor_type are required")

    lat = parse_float(message.get("lat"))
    lon = parse_float(message.get("lon"))
    geom = None
    if lat is not None and lon is not None:
        geom = f"SRID=4326;POINT({lon} {lat})"

    reading_payload = message.get("reading_json") or message.get("reading")
    record = SensorRecord(
        sensor_id=sensor_id,
        sensor_type=sensor_type,
        grid_ref=message.get("grid_ref"),
        recorded_at=parse_timestamp(message.get("recorded_at")),
        lat=lat,
        lon=lon,
        geom_ewkt=geom,
        is_alert=bool(message.get("is_alert", message.get("alert", False))),
        reading=coerce_json(reading_payload),
    )
    return record


def on_connect(client: mqtt.Client, userdata: Any, flags: dict[str, Any], rc: int) -> None:
    if rc == 0:
        logging.info("Connected to MQTT broker", host=MQTT_HOST, port=MQTT_PORT)
        client.subscribe(MQTT_TOPIC, qos=1)
        logging.info("Subscribed to topic", topic=MQTT_TOPIC)
    else:
        logging.error("MQTT connection failed", return_code=rc)


def on_disconnect(client: mqtt.Client, userdata: Any, rc: int) -> None:
    if rc != 0:
        logging.warning("Unexpected MQTT disconnect", return_code=rc)
    else:
        logging.info("MQTT disconnected")


def on_message(client: mqtt.Client, userdata: Any, msg: mqtt.MQTTMessage) -> None:
    writer: PostgisWriter = userdata["writer"]
    try:
        record = build_record(msg.payload)
        writer.insert(record)
        logging.debug("Ingested sensor telemetry", sensor_id=record.sensor_id, topic=msg.topic)
    except ValueError as exc:
        logging.warning("Dropping invalid payload", error=str(exc))
    except Exception as exc:  # Catch-all to keep MQTT loop alive
        logging.exception("Unexpected error while processing message", error=str(exc))


def build_mqtt_client(writer: PostgisWriter) -> mqtt.Client:
    client = mqtt.Client(client_id=MQTT_CLIENT_ID, protocol=mqtt.MQTTv311)
    if MQTT_USERNAME:
        client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)
    client.user_data_set({"writer": writer})
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message
    client.reconnect_delay_set(min_delay=1, max_delay=60)
    client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
    return client


def main() -> None:
    configure_logging()
    writer = PostgisWriter()
    writer.connect()

    mqtt_client = build_mqtt_client(writer)
    stop_event = threading.Event()

    def handle_signal(signum: int, _frame: Any) -> None:
        logging.info("Received shutdown signal", signal=signum)
        stop_event.set()
        mqtt_client.disconnect()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    mqtt_client.loop_start()
    try:
        while not stop_event.is_set():
            time.sleep(1)
    finally:
        mqtt_client.loop_stop()
        writer.close()
        logging.info("PostGIS ingest worker stopped")


if __name__ == "__main__":
    main()
