"""Entrypoint de AWS Lambda (imagen de contenedor).

Se dispara con la notificación S3 del marcador ``_SUCCESS`` o con
``{"run_date": "YYYY-MM-DD"}`` (consola, EventBridge Scheduler, backfills).
La concurrencia reservada de la función es 1 para que dos días no escriban Gold a la vez.
"""

from __future__ import annotations

import logging

from lakehouse.config import load_settings
from lakehouse.events import dates_from_s3_event
from lakehouse.runner import run_dbt

logging.getLogger().setLevel(logging.INFO)
log = logging.getLogger(__name__)


def handler(event: dict, context: object) -> dict:
    dates = dates_from_s3_event(event)
    if not dates:
        log.info("evento sin marcador _SUCCESS, se ignora: %s", event)
        return {"skipped": True}

    settings = load_settings()
    results = []
    for d in dates:
        result = run_dbt(settings, d)
        results.append(result.as_dict())
        if not result.success:
            # Lanzar hace que Lambda reintente la invocación asíncrona y, si se agotan
            # los reintentos, la mande al destino de fallos configurado.
            raise RuntimeError(f"dbt build falló para {d}: {result.nodes}")
    return {"skipped": False, "runs": results}
