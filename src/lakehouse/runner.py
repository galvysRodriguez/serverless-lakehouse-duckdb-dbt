"""Ejecuta el proyecto dbt en proceso (lo mismo en local, Lambda y Cloud Run)."""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field
from datetime import UTC, date, datetime
from pathlib import Path

from dbt.cli.main import dbtRunner

from lakehouse.config import Settings
from lakehouse.metrics import ModelTiming, RunRecord, estimate_cost, new_run_id, record_run, runtime

log = logging.getLogger(__name__)

LAYERS = ("bronze", "silver", "gold")


@dataclass
class RunResult:
    success: bool
    run_date: date | None
    nodes: dict[str, str]
    run_id: str = ""
    duration_s: float = 0.0
    est_cost_usd: float | None = None
    timings: list[ModelTiming] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "success": self.success,
            "run_id": self.run_id,
            "run_date": self.run_date.isoformat() if self.run_date else None,
            "duration_s": round(self.duration_s, 2),
            "est_cost_usd": self.est_cost_usd,
            "nodes": self.nodes,
        }


def run_dbt(
    settings: Settings,
    run_date: date | None,
    *,
    command: str = "build",
    select: str | None = None,
    full_scan: bool = False,
) -> RunResult:
    # dbt lee LAKE_ROOT/DBT_TARGET desde el entorno en profiles.yml y las macros.
    os.environ["LAKE_ROOT"] = settings.lake_root
    os.environ.setdefault("DBT_SEND_ANONYMOUS_USAGE_STATS", "false")

    if settings.scheme == "local":
        # En disco DuckDB no crea carpetas padre; en S3/GCS los "directorios" no existen.
        for layer in LAYERS:
            Path(settings.lake_root, layer).mkdir(parents=True, exist_ok=True)

    if run_date is None and not full_scan:
        run_date = datetime.now(UTC).date()
    dbt_vars = {"full_scan": full_scan}
    if run_date:
        dbt_vars["run_date"] = run_date.isoformat()

    args = [
        command,
        "--project-dir", str(settings.dbt_project_dir),
        "--profiles-dir", str(settings.dbt_project_dir),
        "--target", settings.dbt_target,
        "--target-path", str(settings.dbt_work_dir / "target"),
        "--log-path", str(settings.dbt_work_dir / "logs"),
        "--vars", json.dumps(dbt_vars),
    ]  # fmt: skip
    if select:
        args += ["--select", select]

    log.info("dbt %s", " ".join(args))
    started = datetime.now(UTC)
    res = dbtRunner().invoke(args)
    finished = datetime.now(UTC)

    nodes, timings = {}, []
    for r in res.result or []:
        node = getattr(r, "node", None)
        if node is not None:
            nodes[node.unique_id] = str(r.status)
            timings.append(ModelTiming(node.unique_id, str(r.status), r.execution_time or 0.0))

    duration = (finished - started).total_seconds()
    result = RunResult(
        success=res.success and res.exception is None,
        run_date=run_date,
        nodes=nodes,
        run_id=new_run_id(started),
        duration_s=duration,
        est_cost_usd=estimate_cost(duration),
        timings=timings,
    )
    if command == "build" and not select:
        # Solo las ejecuciones completas del pipeline cuentan para el costo.
        record_run(settings, _record(result, settings, started, finished, full_scan))
    if res.exception:
        raise res.exception
    return result


def _record(
    result: RunResult, settings: Settings, started: datetime, finished: datetime, full_scan: bool
) -> RunRecord:
    return RunRecord(
        run_id=result.run_id,
        run_date=result.run_date,
        full_scan=full_scan,
        started_at=started.replace(tzinfo=None),
        finished_at=finished.replace(tzinfo=None),
        duration_s=result.duration_s,
        success=result.success,
        runtime=runtime(),
        dbt_target=settings.dbt_target,
        nodes_total=len(result.nodes),
        nodes_failed=sum(s in ("error", "fail") for s in result.nodes.values()),
        est_cost_usd=result.est_cost_usd,
        models=result.timings,
    )
