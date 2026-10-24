"""Exporta Gold y ops/pipeline_runs a Parquet sueltos para el dashboard estático.

El dashboard (site/index.html) los consulta en el navegador con DuckDB-WASM. Por HTTP
no se puede listar carpetas, así que las tablas particionadas se consolidan en un
solo archivo por tabla.

    .venv/bin/python scripts/build_site.py --lake data/lake --out site
"""

from __future__ import annotations

import argparse
from pathlib import Path

import duckdb

# archivo de salida -> consulta sobre el lago ({lake} se reemplaza por la raíz).
EXPORTS = {
    "daily_sales": """
        select * exclude (year, month)
        from read_parquet('{lake}/gold/daily_sales/*/*/*.parquet', hive_partitioning = true)
        order by order_date""",
    "product_performance": "from '{lake}/gold/product_performance.parquet'",
    # Sin nombre ni email: el dashboard solo agrega por país.
    "customer_ltv": """
        select customer_id, country, orders_count, lifetime_revenue, segment
        from '{lake}/gold/customer_ltv.parquet'""",
    "pipeline_runs": """
        select run_id, run_date, started_at, duration_s, success, nodes_total,
               raw_bytes, silver_rows, bytes_written, est_cost_usd
        from read_parquet('{lake}/ops/pipeline_runs/*/*/*/*.parquet', union_by_name = true)
        where run_date is not null
        order by started_at""",
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lake", default="data/lake", type=Path)
    parser.add_argument("--out", default="site", type=Path)
    args = parser.parse_args()

    data_dir = args.out / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    lake = args.lake.resolve().as_posix()
    con = duckdb.connect()
    for name, query in EXPORTS.items():
        dest = data_dir / f"{name}.parquet"
        con.execute(f"copy ({query.format(lake=lake)}) to '{dest.as_posix()}' (format parquet)")
        rows = con.execute(f"select count(*) from '{dest.as_posix()}'").fetchall()[0][0]
        print(f"{dest}: {rows} filas")


if __name__ == "__main__":
    main()
