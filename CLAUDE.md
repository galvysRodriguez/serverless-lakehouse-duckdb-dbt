# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Serverless lakehouse: dbt-core + dbt-duckdb over Parquet in object storage, run per day by AWS Lambda or GCP Cloud Run. Docs and code comments are in Spanish. Keep that consistent.

## Commands

```bash
make install                      # .venv + editable install with dev extras
make generate && make run         # synthetic raw data -> dbt build day by day (./data/lake)
make test                         # all pytest (includes e2e that runs dbt; ~20s)
make test-unit                    # pytest -m "not e2e"
.venv/bin/pytest tests/test_events.py::test_only_markers_trigger_a_run   # single test
make lint / make format           # ruff (line length 100)
make smoke DOCKER=podman          # build both images (amd64) + scripts/smoke_images.sh
make site-serve                   # dashboard (DuckDB-WASM) + static dbt docs in site/, on :8000
.venv/bin/lakehouse run --date 2026-10-21 --select tag:gold
.venv/bin/lakehouse run --full-scan      # backfill everything in one run
.venv/bin/lakehouse report --days 30     # cost/duration summary from ops/pipeline_runs
.venv/bin/lakehouse check-freshness      # exit 1 if yesterday wasn't delivered/processed
```

Run raw dbt from `dbt/` with `--profiles-dir .` and `LAKE_ROOT` set. Prefer `lakehouse run`, which sets the vars, target and work dirs the same way the handlers do.

CI (`.github/workflows/ci.yml`) runs lint, pytest, terraform fmt/validate for both clouds, and the image smoke test. Terraform isn't installed locally. Validate with `podman run --rm -v $PWD/infra/aws:/w:Z -w /w docker.io/hashicorp/terraform:1.9.8 validate` after `init -backend=false`.

## Architecture

- **One code path everywhere.** `lakehouse.runner.run_dbt` invokes dbt in-process via `dbtRunner`. The CLI, `handlers/aws_lambda.py` and `handlers/gcp_cloud_run.py` only differ in how they turn an event into dates (`events.py`). Environment selects storage (`LAKE_ROOT`: path / `s3://` / `gs://`) and the profile output (`DBT_TARGET`: local/aws/gcp in `dbt/profiles.yml`).
- **DuckDB is `:memory:`; all state is in the bucket.** Every model is `materialized: external` (Parquet + a view). A fresh process has no views, so the `on-run-start` hook `register_existing_external_models` (in `macros/lake.sql`) creates a view for every external model whose files already exist and adds it to dbt's relation cache. That is what lets `--select tag:gold` rebuild Gold from existing silver files. If you change how locations or read globs are computed, keep the hook consistent with the `external` materialization.
- **Partition contract.** Bronze/silver filter with `{{ partition_filter() }}` (from `var('run_date')`) and write with `partition_by: year, month, day` + `overwrite_or_ignore` + `filename_pattern 'part_{i}'` (set in `dbt_project.yml`). This is what makes re-runs idempotent and reads pruned. Partition values are unpadded ints (`day=3`); `partitions.hive_path` must match DuckDB's output.
- **File locations** come from the overridden `external_location` macro: `<LAKE_ROOT>/<schema>/<model name minus prefix>`. Model names therefore need a `brz_`/`slv_`/`gld_` prefix, and the prefix-less entity name must be unique per layer.
- **Order versions.** Raw orders reappear on later days with a new status. Silver keeps one row per key *per day partition*. Its `latest_by` keys include `year, month, day`, so `full_scan` backfills keep per-day semantics.
- **Incremental Gold.** `affected_months(ref('slv_orders'))` runs a query at compile time: the order months touched by today's silver partition, plus run_date's month. `int_*_current` (ephemeral) read silver only from `arrival_window(months)` and keep orders `in_months(...)`. `models/gold/monthly/*` are partitioned by `year, month` and only rewrite those months. `gld_customer_ltv`/`gld_product_performance` are full rewrites over the monthly aggregates. `gld_dim_*` are SCD1 merges of `{{ this }}` (when `self_exists()`) with today's changes. Any new Gold model must keep `test_incremental_gold_equals_full_rebuild` passing (incremental day-by-day == `--full-scan`).
- **Tests on bronze/silver** get `where: "__run_partition__"` from `dbt_project.yml`. The overridden `get_where_subquery` macro expands it. Generic-test `where` configs can't call project macros directly.
- **Run metrics.** `run_dbt` records every full `build` (no `--select`) via `metrics.record_run` to `ops/pipeline_runs/…/<run_id>.parquet`, with an explicit schema (`_COLUMNS`) so files stay union-readable. Recording must never fail the pipeline; it logs and returns None. Cost = duration × `LAKEHOUSE_COST_PER_SECOND` (computed in Terraform from list prices). The `ops/` prefix must stay writable in IAM.
- **Contracts.** Every silver/gold model has `contract: enforced` (`data_type` per column in `_silver.yml`/`_gold.yml`). Changing a model's output columns or types means updating its yml. Silver keys also have `not_null` *constraints*, enforced by DuckDB on write. Gold uses tests instead, because a constraint would break dbt-duckdb's NULL placeholder row for empty models. Types come from DuckDB's actual output (e.g. hive partition columns are `bigint`).
- **Freshness.** `{"check": "freshness"}` (EventBridge Scheduler / Cloud Scheduler, daily) makes the handlers fail when yesterday (`FRESHNESS_LAG_DAYS`) lacks a marker or a successful row in `ops/pipeline_runs`. Failing is what triggers the alerts.
- **Trigger** is only `raw/ecommerce/_markers/year=…/month=…/day=…/_SUCCESS` (`partitions.run_date_from_marker`). Both clouds filter by that prefix at the source. Concurrency is 1 by design (Gold is fully rewritten each run).

## Gotchas

- Importing dbt installs a root logging handler. Use `logging.basicConfig(..., force=True)`.
- DuckDB 2.x: relations have no `fetchone()`; use `.fetchall()`. Lambda syntax is `lambda x: …`, not `x -> …`.
- Locally DuckDB won't create parent dirs; `run_dbt` and `generate_day` create them for local paths only.
- Containers: DuckDB extensions are pre-installed at build into `/opt/duckdb/extensions` (`DUCKDB_EXTENSION_DIRECTORY`). Lambda's filesystem is read-only except `/tmp`, hence `DBT_WORK_DIR=/tmp/dbt` and `HOME=/tmp`. Test the Lambda image locally with `--read-only --tmpfs /tmp` and its built-in emulator on `:8080/2015-03-31/functions/function/invocations`.
- GCS access from DuckDB uses HMAC keys (`GCS_HMAC_KEY_ID`/`GCS_HMAC_SECRET`), not ADC.
