"""Chequeo de frescura: ¿llegó y se procesó el día esperado?

El pipeline solo corre cuando aparece un marcador ``_SUCCESS``. Si el productor no
entrega, no hay ejecución y tampoco error que alerte, así que un job programado
llama a este chequeo y falla (para disparar las alertas) si falta algo.
"""

from __future__ import annotations

import os
from datetime import UTC, date, datetime, timedelta

from lakehouse.config import Settings
from lakehouse.duck import connect
from lakehouse.metrics import OPS_PREFIX
from lakehouse.partitions import hive_path, marker_key


def expected_date(today: date | None = None) -> date:
    lag = int(os.environ.get("FRESHNESS_LAG_DAYS", "1"))
    return (today or datetime.now(UTC).date()) - timedelta(days=lag)


def check(settings: Settings, d: date) -> list[str]:
    """Problemas encontrados para el día ``d`` (lista vacía = todo en orden)."""
    con = connect(settings)
    root = settings.lake_root

    def count(sql: str) -> int:
        try:
            return int(con.execute(sql).fetchall()[0][0] or 0)
        except Exception:  # "No files found" cuando el glob no encuentra nada
            return 0

    problems = []
    if not count(f"select count(*) from glob('{root}/{marker_key(d)}')"):
        problems.append(f"{d}: no llegó el marcador {marker_key(d)}")
    runs = f"{root}/{OPS_PREFIX}/{hive_path(d)}/*.parquet"
    if not count(f"select count(*) from read_parquet('{runs}') where success"):
        problems.append(f"{d}: no hay ninguna ejecución exitosa en {OPS_PREFIX}")
    con.close()
    return problems
