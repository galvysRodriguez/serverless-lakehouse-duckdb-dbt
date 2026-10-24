"""Registro de cada ejecución en ``ops/pipeline_runs/`` y reporte de costos.

Una fila por ejecución, en un archivo propio (append-only, sin sobrescribir):

    ops/pipeline_runs/year=2026/month=10/day=21/<run_id>.parquet

El costo es una **estimación de cómputo**: duración medida x precio por segundo de
la configuración desplegada (``LAKEHOUSE_COST_PER_SECOND`` y ``LAKEHOUSE_COST_PER_RUN``,
que calcula Terraform con precios de lista). No incluye almacenamiento, requests a
S3/GCS ni capa gratuita.
"""

from __future__ import annotations

import json
import logging
import os
import tempfile
import uuid
from dataclasses import asdict, dataclass, field
from datetime import date, datetime
from pathlib import Path

from lakehouse.config import Settings
from lakehouse.duck import connect
from lakehouse.partitions import RAW_PREFIX, hive_path

log = logging.getLogger(__name__)

OPS_PREFIX = "ops/pipeline_runs"


@dataclass
class ModelTiming:
    model: str
    status: str
    seconds: float


@dataclass
class RunRecord:
    run_id: str
    run_date: date | None
    full_scan: bool
    started_at: datetime
    finished_at: datetime
    duration_s: float
    success: bool
    runtime: str
    dbt_target: str
    nodes_total: int
    nodes_failed: int
    raw_bytes: int | None = None
    bronze_rows: int | None = None
    silver_rows: int | None = None
    bytes_written: int | None = None
    est_cost_usd: float | None = None
    models: list[ModelTiming] = field(default_factory=list)


def runtime() -> str:
    if os.environ.get("AWS_LAMBDA_FUNCTION_NAME"):
        return "aws-lambda"
    if os.environ.get("K_SERVICE"):
        return "gcp-cloud-run"
    return "local"


def estimate_cost(duration_s: float) -> float | None:
    per_second = os.environ.get("LAKEHOUSE_COST_PER_SECOND")
    if per_second is None:
        return None
    per_run = float(os.environ.get("LAKEHOUSE_COST_PER_RUN", "0"))
    return round(duration_s * float(per_second) + per_run, 8)


def new_run_id(started_at: datetime) -> str:
    return f"{started_at:%Y%m%dT%H%M%S}-{uuid.uuid4().hex[:8]}"


def _volumes(con, settings: Settings, run_date: date | None) -> dict[str, int | None]:
    """Bytes de raw leídos y filas/bytes escritos en bronze y silver para el día."""
    if run_date is None:  # full_scan: no hay una partición única que medir
        return {}
    root, part = settings.lake_root, hive_path(run_date)

    def scalar(sql: str) -> int | None:
        try:
            value = con.execute(sql).fetchall()[0][0]
            return int(value) if value is not None else 0
        except Exception as exc:  # p. ej. "No files found" si una capa falló
            log.warning("métrica no disponible: %s", exc)
            return None

    # read_blob no descarga el contenido si solo se proyecta `size`.
    raw = scalar(f"select sum(size) from read_blob('{root}/{RAW_PREFIX}/*/{part}/*.json')")
    rows = {
        layer: scalar(
            f"select sum(num_rows) from parquet_file_metadata('{root}/{layer}/*/{part}/*.parquet')"
        )
        for layer in ("bronze", "silver")
    }
    written = scalar(
        "select sum(total_compressed_size) from parquet_metadata("
        f"['{root}/bronze/*/{part}/*.parquet', '{root}/silver/*/{part}/*.parquet'])"
    )
    return {
        "raw_bytes": raw,
        "bronze_rows": rows["bronze"],
        "silver_rows": rows["silver"],
        "bytes_written": written,
    }


def record_run(settings: Settings, rec: RunRecord) -> str | None:
    """Escribe la fila de la ejecución. Nunca hace fallar el pipeline."""
    try:
        con = connect(settings)
        for key, value in _volumes(con, settings, rec.run_date).items():
            setattr(rec, key, value)

        day = rec.run_date or rec.started_at.date()
        dest = f"{settings.lake_root}/{OPS_PREFIX}/{hive_path(day)}/{rec.run_id}.parquet"
        if settings.scheme == "local":
            Path(dest).parent.mkdir(parents=True, exist_ok=True)

        row = asdict(rec)
        row["run_date"] = rec.run_date.isoformat() if rec.run_date else None
        row["started_at"] = rec.started_at.isoformat()
        row["finished_at"] = rec.finished_at.isoformat()
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tmp:
            json.dump(row, tmp)
        con.execute(
            f"""
            copy (
                select * replace (
                    cast(run_date as date) as run_date,
                    cast(started_at as timestamp) as started_at,
                    cast(finished_at as timestamp) as finished_at
                )
                from read_json('{tmp.name}', columns = {_COLUMNS})
            ) to '{dest}' (format parquet)
            """
        )
        os.unlink(tmp.name)
        con.close()
        return dest
    except Exception:
        log.exception("no se pudo registrar la ejecución %s", rec.run_id)
        return None


# Esquema explícito: evita que la inferencia cambie tipos entre ejecuciones (p. ej.
# un None se inferiría como JSON) y que los archivos dejen de poder leerse juntos.
_COLUMNS = """{
    'run_id': 'VARCHAR', 'run_date': 'VARCHAR', 'full_scan': 'BOOLEAN',
    'started_at': 'VARCHAR', 'finished_at': 'VARCHAR', 'duration_s': 'DOUBLE',
    'success': 'BOOLEAN', 'runtime': 'VARCHAR', 'dbt_target': 'VARCHAR',
    'nodes_total': 'INTEGER', 'nodes_failed': 'INTEGER', 'raw_bytes': 'BIGINT',
    'bronze_rows': 'BIGINT', 'silver_rows': 'BIGINT', 'bytes_written': 'BIGINT',
    'est_cost_usd': 'DOUBLE',
    'models': 'STRUCT(model VARCHAR, status VARCHAR, seconds DOUBLE)[]'
}"""


def report(settings: Settings, days: int = 30) -> str:
    """Resumen de las ejecuciones de los últimos ``days`` días, como texto."""
    con = connect(settings)
    runs = (
        f"read_parquet('{settings.lake_root}/{OPS_PREFIX}/*/*/*/*.parquet', union_by_name = true)"
    )
    window = f"started_at >= now()::timestamp - interval {int(days)} day"
    try:
        con.execute(f"create temp view runs as select * from {runs} where {window}")
    except Exception as exc:
        return f"Sin ejecuciones registradas en {settings.lake_root}/{OPS_PREFIX} ({exc})"

    sections = {
        "Resumen": """
            select count(*) as ejecuciones,
                   count(*) filter (where not success) as fallidas,
                   round(avg(duration_s), 1) as duracion_media_s,
                   round(max(duration_s), 1) as duracion_max_s,
                   round(sum(est_cost_usd), 6) as costo_estimado_usd,
                   -- costo medio por día de datos x 30: un backfill no infla la proyección
                   round(sum(est_cost_usd) / nullif(count(distinct run_date), 0) * 30, 4)
                       as proyeccion_mensual_usd
            from runs""",
        "Por día": """
            select coalesce(run_date, started_at::date) as dia_datos, count(*) as ejecuciones,
                   round(sum(duration_s), 1) as segundos, sum(silver_rows) as filas_silver,
                   round(sum(raw_bytes) / 1e6, 2) as mb_raw,
                   round(sum(est_cost_usd), 6) as costo_usd
            from runs group by all order by dia_datos desc limit 14""",
        "Modelos más lentos (media)": """
            select m.model, round(avg(m.seconds), 2) as segundos_medios, count(*) as veces
            from runs, unnest(models) as u(m)
            group by all order by segundos_medios desc limit 8""",
    }
    out = []
    for title, sql in sections.items():
        out.append(f"== {title}\n{con.sql(sql)}")
    con.close()
    return "\n".join(out)
