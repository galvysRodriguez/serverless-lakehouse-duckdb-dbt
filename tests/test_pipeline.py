"""Prueba de punta a punta contra un lago local temporal."""

from datetime import date, timedelta
from pathlib import Path

import duckdb
import pytest

from lakehouse.config import Settings, load_settings
from lakehouse.generate import generate_day
from lakehouse.runner import run_dbt

pytestmark = pytest.mark.e2e

DAYS = [date(2026, 10, 1) + timedelta(days=i) for i in range(3)]


@pytest.fixture(scope="module")
def lake(tmp_path_factory) -> Settings:
    root = tmp_path_factory.mktemp("lake")
    base = load_settings()
    settings = Settings(
        lake_root=str(root),
        dbt_target="local",
        dbt_project_dir=base.dbt_project_dir,
        dbt_work_dir=root / "_dbt",
    )
    for d in DAYS:
        generate_day(settings, d)
        assert run_dbt(settings, d).success
    return settings


def _one(sql: str):
    return duckdb.sql(sql).fetchall()[0]


def test_layers_are_hive_partitioned(lake: Settings):
    root = Path(lake.lake_root)
    for layer, entity in [("bronze", "orders"), ("silver", "orders"), ("silver", "order_items")]:
        days = sorted(p.name for p in (root / layer / entity / "year=2026" / "month=10").iterdir())
        assert days == ["day=1", "day=2", "day=3"]
    assert (root / "gold" / "daily_sales.parquet").is_file()


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
    gold = f"{lake.lake_root}/gold/daily_sales.parquet"

    def snapshot():
        return _one(f"select count(*) from '{silver}'"), _one(
            f"select sum(gross_revenue) from '{gold}'"
        )

    before = snapshot()
    assert run_dbt(lake, DAYS[-1]).success
    assert snapshot() == before


def test_gold_reflects_order_lifecycle(lake: Settings):
    gold = f"{lake.lake_root}/gold/daily_sales.parquet"
    # Los pedidos del primer día ya recibieron sus cambios de estado de los días 2 y 3.
    cancelled = _one(f"select cancelled_count from '{gold}' where order_date = '{DAYS[0]}'")[0]
    assert cancelled > 0
