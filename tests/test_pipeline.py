"""Prueba de punta a punta contra lagos locales temporales."""

import shutil
from datetime import date, timedelta
from pathlib import Path

import duckdb
import pytest

from lakehouse.config import Settings, load_settings
from lakehouse.generate import generate_day
from lakehouse.runner import run_dbt

pytestmark = pytest.mark.e2e

# Cruza un cambio de mes: los pedidos del 30/09 cambian de estado en octubre.
DAYS = [date(2026, 9, 29) + timedelta(days=i) for i in range(4)]

GOLD_TABLES = {
    "daily_sales": "order_date",
    "customer_monthly": "customer_id, order_month",
    "product_monthly": "product_id, order_month",
    "dim_customers": "customer_id",
    "dim_products": "product_id",
    "customer_ltv": "customer_id",
    "product_performance": "product_id",
}


def _settings(root: Path) -> Settings:
    base = load_settings()
    return Settings(
        lake_root=str(root),
        dbt_target="local",
        dbt_project_dir=base.dbt_project_dir,
        dbt_work_dir=root / "_dbt",
    )


@pytest.fixture(scope="module")
def lake(tmp_path_factory) -> Settings:
    settings = _settings(tmp_path_factory.mktemp("lake"))
    for d in DAYS:
        generate_day(settings, d)
        assert run_dbt(settings, d).success
    return settings


def _one(sql: str):
    return duckdb.sql(sql).fetchall()[0]


def _gold(settings: Settings, table: str) -> str:
    """SQL que lee una tabla gold, particionada (carpeta) o no (archivo)."""
    root = Path(settings.lake_root, "gold")
    if (root / f"{table}.parquet").is_file():
        return f"select * from '{root}/{table}.parquet'"
    return f"select * exclude (year, month) from '{root}/{table}/*/*/*.parquet'"


def test_layers_are_hive_partitioned(lake: Settings):
    root = Path(lake.lake_root)
    for layer, entity in [("bronze", "orders"), ("silver", "orders"), ("silver", "order_items")]:
        parts = sorted(
            str(p.relative_to(root / layer / entity)) for p in (root / layer / entity).glob("*/*/*")
        )
        assert parts == [
            "year=2026/month=10/day=1",
            "year=2026/month=10/day=2",
            "year=2026/month=9/day=29",
            "year=2026/month=9/day=30",
        ]
    months = sorted(p.name for p in (root / "gold" / "daily_sales").glob("year=2026/*"))
    assert months == ["month=10", "month=9"]


def test_silver_removes_duplicates_and_normalizes_status(lake: Settings):
    silver = f"{lake.lake_root}/silver/orders/*/*/*/*.parquet"
    dupes, statuses = _one(
        f"select count(*) - count(distinct (order_id, year, month, day)), "
        f"list(distinct status order by status) from '{silver}'"
    )
    assert dupes == 0
    assert statuses == ["cancelled", "delivered", "placed", "shipped"]


def test_rerunning_a_day_is_idempotent(lake: Settings):
    silver = f"{lake.lake_root}/silver/orders/*/*/*/*.parquet"

    def snapshot():
        rows = _one(f"select count(*) from '{silver}'")
        revenue = _one(f"select sum(gross_revenue) from ({_gold(lake, 'daily_sales')})")
        return rows, revenue

    before = snapshot()
    assert run_dbt(lake, DAYS[-1]).success
    assert snapshot() == before


def test_gold_reflects_order_lifecycle(lake: Settings):
    # Los pedidos del primer día ya recibieron sus cambios de estado de los días 2 y 3.
    cancelled = _one(
        f"select cancelled_count from ({_gold(lake, 'daily_sales')}) where order_date = '{DAYS[0]}'"
    )[0]
    assert cancelled > 0


def test_incremental_gold_equals_full_rebuild(lake: Settings, tmp_path):
    """Gold incremental por mes debe dar lo mismo que reprocesar todo de una vez."""
    full = _settings(tmp_path / "full")
    shutil.copytree(Path(lake.lake_root, "raw"), tmp_path / "full" / "raw")
    assert run_dbt(full, None, full_scan=True).success

    for table in GOLD_TABLES:
        inc_sql, full_sql = _gold(lake, table), _gold(full, table)
        missing = _one(f"select count(*) from (({inc_sql}) except all ({full_sql}))")[0]
        extra = _one(f"select count(*) from (({full_sql}) except all ({inc_sql}))")[0]
        assert (missing, extra) == (0, 0), table


def test_each_run_is_recorded_in_ops(lake: Settings):
    runs = f"{lake.lake_root}/ops/pipeline_runs/*/*/*/*.parquet"
    total, ok, min_rows, with_models = _one(
        f"select count(*), count(*) filter (where success), min(silver_rows), "
        f"count(*) filter (where len(models) > 0) from '{runs}' where not full_scan"
    )
    assert total >= len(DAYS)
    assert ok == total == with_models
    assert min_rows > 0
