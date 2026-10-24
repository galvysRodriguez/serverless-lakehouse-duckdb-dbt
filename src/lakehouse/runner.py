"""Ejecuta el proyecto dbt en proceso (lo mismo en local, Lambda y Cloud Run)."""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from datetime import date
from pathlib import Path

from dbt.cli.main import dbtRunner

from lakehouse.config import Settings

log = logging.getLogger(__name__)

LAYERS = ("bronze", "silver", "gold")


@dataclass
class RunResult:
    success: bool
    run_date: date | None
    nodes: dict[str, str]

    def as_dict(self) -> dict:
        return {
            "success": self.success,
            "run_date": self.run_date.isoformat() if self.run_date else None,
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
    res = dbtRunner().invoke(args)
    if res.exception:
        raise res.exception

    nodes = {}
    for r in res.result or []:
        node = getattr(r, "node", None)
        if node is not None:
            nodes[node.unique_id] = str(r.status)
    return RunResult(success=res.success, run_date=run_date, nodes=nodes)
