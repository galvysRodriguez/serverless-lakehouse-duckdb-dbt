"""Utilidades para rutas con particionamiento estilo Hive (year=/month=/day=)."""

from __future__ import annotations

import re
from datetime import date

RAW_PREFIX = "raw/ecommerce"
# Archivo marcador que el productor escribe cuando terminó de cargar un día completo.
# Es el único objeto que dispara el pipeline, así un día con varios archivos
# genera una sola ejecución.
MARKER_PREFIX = f"{RAW_PREFIX}/_markers"
MARKER_NAME = "_SUCCESS"

_HIVE_DATE = re.compile(r"year=(\d{4})/month=(\d{1,2})/day=(\d{1,2})(?:/|$)")


def hive_path(d: date) -> str:
    """Segmento de partición para una fecha, p. ej. ``year=2026/month=10/day=3``.

    Sin ceros a la izquierda: es lo que produce ``COPY ... PARTITION_BY`` de DuckDB
    con columnas enteras, así las capas raw, bronze y silver usan el mismo formato.
    """
    return f"year={d.year}/month={d.month}/day={d.day}"


def marker_key(d: date) -> str:
    return f"{MARKER_PREFIX}/{hive_path(d)}/{MARKER_NAME}"


def date_from_key(key: str) -> date | None:
    """Extrae la fecha de partición de una ruta de objeto, o ``None`` si no tiene."""
    match = _HIVE_DATE.search(key)
    if not match:
        return None
    year, month, day = (int(g) for g in match.groups())
    try:
        return date(year, month, day)
    except ValueError:
        return None


def run_date_from_marker(key: str) -> date | None:
    """Fecha a procesar si ``key`` es un marcador ``_SUCCESS`` válido; si no, ``None``."""
    if not key.startswith(f"{MARKER_PREFIX}/") or not key.endswith(f"/{MARKER_NAME}"):
        return None
    return date_from_key(key)
