"""Entrypoint de AWS Lambda (imagen de contenedor).

Se dispara con la notificación S3 del marcador ``_SUCCESS`` o con
``{"run_date": "YYYY-MM-DD"}`` (consola, backfills). EventBridge Scheduler la llama
a diario con ``{"check": "freshness"}``.
La concurrencia reservada de la función es 1 para que dos días no escriban Gold a la vez.
"""

from __future__ import annotations

import logging

from lakehouse import freshness
from lakehouse.config import load_settings
from lakehouse.events import dates_from_s3_event, is_freshness_check
from lakehouse.runner import run_dbt

logging.getLogger().setLevel(logging.INFO)
log = logging.getLogger(__name__)


def handler(event: dict, context: object) -> dict:
    if is_freshness_check(event):
        d = freshness.expected_date()
        problems = freshness.check(load_settings(), d)
        if problems:
            # El error dispara la alarma de errores y el destino de fallos (SNS).
            raise RuntimeError("; ".join(problems))
        return {"freshness": "ok", "date": d.isoformat()}

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
