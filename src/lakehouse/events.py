"""Traduce los eventos de cada nube a la lista de días que hay que procesar.

Fuentes soportadas:
- AWS: notificación S3 ``ObjectCreated`` (directa a Lambda).
- GCP: notificación GCS -> Pub/Sub push hacia Cloud Run.
- Ambas: invocación manual o programada con ``{"run_date": "YYYY-MM-DD"}``.
"""

from __future__ import annotations

import base64
import json
from datetime import date
from urllib.parse import unquote_plus

from lakehouse.partitions import run_date_from_marker


def _manual(payload: dict) -> list[date] | None:
    if "run_date" in payload:
        return [date.fromisoformat(payload["run_date"])]
    return None


def dates_from_s3_event(event: dict) -> list[date]:
    if (manual := _manual(event)) is not None:
        return manual
    dates = set()
    for record in event.get("Records", []):
        # Las claves llegan URL-encoded ("year%3D2026" o espacios como "+").
        key = unquote_plus(record.get("s3", {}).get("object", {}).get("key", ""))
        if d := run_date_from_marker(key):
            dates.add(d)
    return sorted(dates)


def dates_from_pubsub_push(body: dict) -> list[date]:
    if (manual := _manual(body)) is not None:
        return manual
    message = body.get("message", {})
    # Las notificaciones de GCS traen el nombre del objeto como atributo y en el payload.
    name = message.get("attributes", {}).get("objectId")
    if not name and message.get("data"):
        name = json.loads(base64.b64decode(message["data"])).get("name")
    d = run_date_from_marker(name or "")
    return [d] if d else []
