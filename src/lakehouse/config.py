"""Configuración por variables de entorno, compartida por la CLI y los handlers."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class Settings:
    # Raíz del lago: ruta local, s3://bucket o gs://bucket (sin barra final).
    lake_root: str
    # Target de dbt/profiles.yml: local | aws | gcp.
    dbt_target: str
    dbt_project_dir: Path
    # Directorio escribible para target/ y logs/ de dbt (en Lambda solo /tmp lo es).
    dbt_work_dir: Path

    @property
    def scheme(self) -> str:
        if self.lake_root.startswith("s3://"):
            return "s3"
        if self.lake_root.startswith(("gs://", "gcs://")):
            return "gcs"
        return "local"


def load_settings() -> Settings:
    lake_root = os.environ.get("LAKE_ROOT", str(_REPO_ROOT / "data" / "lake")).rstrip("/")
    return Settings(
        lake_root=lake_root,
        dbt_target=os.environ.get("DBT_TARGET", "local"),
        dbt_project_dir=Path(os.environ.get("DBT_PROJECT_DIR", _REPO_ROOT / "dbt")),
        dbt_work_dir=Path(os.environ.get("DBT_WORK_DIR", _REPO_ROOT / "dbt")),
    )
