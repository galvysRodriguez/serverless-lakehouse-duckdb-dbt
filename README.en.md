# Serverless lakehouse: DuckDB + dbt-core on S3/GCS

[![CI](https://github.com/galvysRodriguez/serverless-lakehouse-duckdb-dbt/actions/workflows/ci.yml/badge.svg)](https://github.com/galvysRodriguez/serverless-lakehouse-duckdb-dbt/actions/workflows/ci.yml)
[![Pages](https://github.com/galvysRodriguez/serverless-lakehouse-duckdb-dbt/actions/workflows/pages.yml/badge.svg)](https://galvysrodriguez.github.io/serverless-lakehouse-duckdb-dbt/)
![Python](https://img.shields.io/badge/python-3.11%2B-3776ab)
![dbt](https://img.shields.io/badge/dbt--core-1.10%2B-ff694b)
![DuckDB](https://img.shields.io/badge/DuckDB-Parquet-fff000)
![Terraform](https://img.shields.io/badge/Terraform-AWS%20%7C%20GCP-7b42bc)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[Español](README.md) · **English** ·
[**Live demo**](https://galvysrodriguez.github.io/serverless-lakehouse-duckdb-dbt/) ·
[dbt lineage](https://galvysrodriguez.github.io/serverless-lakehouse-duckdb-dbt/dbt/)

> **TL;DR.** A data warehouse that doesn't pay to stay on. Data lives as Parquet in
> S3/GCS. Each day of data triggers a Lambda (or Cloud Run) that runs `dbt build` on
> an in-memory DuckDB and shuts down. Every run reads only that day's partition, and
> Gold recomputes only the affected months. A test checks that the incremental result
> is identical to a full rebuild. Every run records its duration and estimated cost,
> and a daily check alerts when a day didn't arrive. Same code locally, on AWS and on
> GCP, with Terraform for both clouds.

![Architecture](docs/architecture.svg)

No always-on servers: data lives as Parquet in object storage, **DuckDB** processes it
in memory, and **dbt-core** (`dbt-duckdb`) defines the **Bronze → Silver → Gold**
layers. Compute runs on **AWS Lambda** or **GCP Cloud Run**, is event-driven and
scales to zero.

The same code runs locally, on AWS and on GCP. Only `LAKE_ROOT` (a folder, `s3://` or
`gs://`) and `DBT_TARGET` (`local`, `aws`, `gcp`) change.

<details>
<summary>Bucket path flow</summary>

```
 producer ──► raw/ecommerce/<entity>/year=/month=/day=/*.json
             raw/ecommerce/_markers/year=/month=/day=/_SUCCESS ──┐
                                                                │ event
            ┌───────────────────────────────────────────────────┘
            ▼
   AWS: S3 notification ──► Lambda (image)            ┐
   GCP: GCS notification ──► Pub/Sub push ──► Cloud Run ├─► dbt build --vars run_date=YYYY-MM-DD
                                                      ┘        │  DuckDB :memory:
                                                               ▼
   bronze/<entity>/year=/month=/day=/part_0.parquet   (that day's partition only)
   silver/<entity>/year=/month=/day=/part_0.parquet   (that day's partition only)
   gold/<table>/year=/month=/part_0.parquet           (affected months only)
   gold/<table>.parquet                               (dimensions and totals)
```

</details>

## Demo

[galvysrodriguez.github.io/serverless-lakehouse-duckdb-dbt](https://galvysrodriguez.github.io/serverless-lakehouse-duckdb-dbt/) is a static
site that `.github/workflows/pages.yml` rebuilds on every push to `main`:

- **Dashboard**: downloads the Gold and `ops/pipeline_runs` Parquet files and queries
  them in the browser with DuckDB-WASM, no backend. It shows sales and also what it
  costs to produce them: the duration of each daily run and its estimated cost at
  Lambda prices.
- **dbt docs** (`/dbt/`): models, columns with their contracts, tests and lineage.

The data is synthetic: the workflow generates ~2 months, runs the pipeline day by day
as the events would, and publishes the result. Locally: `make site-serve`.

## Quick start (local)

Requires Python ≥ 3.11.

```bash
make install         # creates .venv and installs the package + dbt-duckdb
make generate        # 7 days of synthetic e-commerce data in ./data/lake/raw
make run             # dbt build day by day (as each event would)
make test            # pytest: unit + end-to-end pipeline
```

Query the result with DuckDB:

```bash
.venv/bin/python -c "import duckdb; print(duckdb.sql(\"from 'data/lake/gold/customer_ltv.parquet'\"))"
```

Other commands:

```bash
.venv/bin/lakehouse run --date 2026-10-21                 # reprocess one day (idempotent)
.venv/bin/lakehouse run --date 2026-10-21 --select tag:gold
make generate START=2026-09-01 END=2026-09-30             # custom range
make test-unit                                            # without the e2e test
.venv/bin/lakehouse report --days 30                      # duration and estimated cost per run
.venv/bin/lakehouse check-freshness                       # did yesterday arrive and get processed?
make lint
make smoke                                                # Lambda/Cloud Run images against a local lake
make docs                                                 # dbt lineage on localhost:8080
make site-serve                                           # dashboard + dbt docs on localhost:8000
```

## Layers

| Layer  | Models | What it does | Writes |
|--------|--------|--------------|--------|
| Raw    | (producer) | NDJSON as delivered. `orders` carries new orders **and** status changes from previous days (CDC), with intentional duplicates and noise. | immutable |
| Bronze | `brz_orders`, `brz_customers`, `brz_products` | Typed read of the day's raw + `_source_file`, `_loaded_at`. | day partition |
| Silver | `slv_orders`, `slv_order_items`, `slv_customers`, `slv_products` | Cleaning (normalized status/email), in-day deduplication, unnesting of items. | day partition |
| Gold   | `gld_daily_sales`, `gld_customer_monthly`, `gld_product_monthly` | Aggregates by order creation month, using the current version of each order. | affected months only |
| Gold   | `gld_dim_customers`, `gld_dim_products` | SCD1 dimensions: previous version + the day's changes. | full file (small) |
| Gold   | `gld_customer_ltv`, `gld_product_performance` | All-time totals summed from the monthly aggregates. | full file (small) |

## Quality: contracts, volume and freshness

- **Contracts** (`contract: enforced`) on every Silver and Gold model: fixed column
  names and types, plus `not_null` on Silver keys, enforced by DuckDB on write. If the
  producer changes the raw shape, the build fails in Silver. Bronze keeps the data as
  it arrived and Gold is left untouched.
- **Volume**: `assert_bronze_orders_not_empty` fails if a day has a marker but no
  orders.
- **Freshness**: if the producer doesn't deliver, there is no event and no error. A
  daily job (EventBridge Scheduler / Cloud Scheduler, 07:00 UTC) calls the pipeline
  with `{"check": "freshness"}`. It fails if the previous day lacks the marker or a
  successful run in `ops/pipeline_runs`, which triggers the alerts. Locally:
  `lakehouse check-freshness --date 2026-10-21`.
- **dbt tests**: `accepted_values` and per-partition uniqueness in Silver (only the
  processed partition); `unique`/`not_null` in Gold; reconciliation of daily revenue
  = sum of line items for the recomputed months.

## Partitioning and idempotency

- Hive-style `year=/month=/day=` paths in raw, bronze and silver. Bronze and silver
  filter on those columns and DuckDB reads **only** that day's folder (partition
  pruning). Verified with `EXPLAIN ANALYZE`: `Scanning Files: 1/3`.
- Each partition is written as `part_{i}.parquet` with `OVERWRITE_OR_IGNORE`, so
  reprocessing a day overwrites its files without duplicating anything or touching
  other days.
- DuckDB runs `:memory:`: all state is in the bucket, so any ephemeral instance can
  process any day.
- A single object triggers the pipeline: the `_SUCCESS` marker that the producer
  writes **after** uploading all of the day's feeds.
- Backfill the whole history: `lakehouse run --full-scan` (reads the whole lake).
- On start, a hook registers views over the Parquet files that already exist. That's
  why `--select tag:gold` rebuilds Gold from silver without re-reading raw or bronze.

## Incremental Gold by month

A day of data can only change the months in which the orders that arrived that day
were created (new orders and status changes). `affected_months()` computes them from
that day's silver partition, and Gold:

1. Reads silver only from the first day of the oldest affected month. DuckDB skips
   the remaining files using the partition columns.
2. Rewrites only the `year=/month=` partitions of those months in `gld_daily_sales`,
   `gld_customer_monthly` and `gld_product_monthly`.
3. Recomputes the totals (`gld_customer_ltv`, `gld_product_performance`) by summing
   those monthly aggregates (one row per customer or product and month), not silver.
4. Updates the dimensions by merging their previous version with the day's changes.

Daily cost depends on the current month, not on the size of the history. The test
`test_incremental_gold_equals_full_rebuild` checks that the result is identical to
reprocessing everything with `--full-scan`.

Assumption: changes to an order always arrive after its creation. If a producer
resends data for old months, that month is still recomputed because it enters
`affected_months`; more silver is read, that's all.

## Cost per run

Every full `dbt build` leaves a row in
`ops/pipeline_runs/year=/month=/day=/<run_id>.parquet` (append-only) with:

- duration and outcome, plus the time of each model and test;
- raw bytes read, bronze/silver rows and Parquet bytes written for the day;
- `est_cost_usd`: duration × price per second of the deployed configuration.

Terraform computes that price from the configured memory/CPU and list prices
(variables `lambda_price_per_gb_second` and `price_per_*`, worth checking for your
region) and passes it as `LAKEHOUSE_COST_PER_SECOND`. It's a compute estimate: it
excludes storage, S3/GCS requests, cold starts and the free tier. Locally it's empty.

```bash
LAKE_ROOT=s3://my-bucket .venv/bin/lakehouse report --days 30
```

It prints the summary (runs, failures, duration, cost and monthly projection), the
per-data-day detail and the slowest models. The table can be queried directly with
DuckDB or any tool that reads Parquet.

## Deployment

Both clouds follow the same two-phase pattern, because the function/service needs the
image to exist before it can be created:

### AWS (S3 + Lambda)

```bash
cp infra/aws/terraform.tfvars.example infra/aws/terraform.tfvars   # edit bucket_name, email
make aws-bootstrap          # creates the ECR repository
make aws-deploy TAG=v1      # arm64 build + push + terraform apply
```

Creates: an encrypted bucket with public access blocked and lifecycle rules; ECR
keeping 5 images; an arm64 image Lambda (3 GB, 15 min, reserved concurrency 1) with
read-only access to `raw/` and write access to `bronze/ silver/ gold/`; an S3
notification filtered to `raw/ecommerce/_markers/*_SUCCESS`; logs with 14-day
retention; SNS alerts; an optional monthly budget.

To trigger a day by hand: `aws lambda invoke --function-name lakehouse --payload '{"run_date":"2026-10-21"}' --cli-binary-format raw-in-base64-out out.json`.

> Building arm64 on an x86 machine requires emulation (`docker buildx` with QEMU).
> If you prefer x86, use `AWS_PLATFORM=linux/amd64` and `lambda_architecture = "x86_64"`.

### GCP (GCS + Cloud Run)

```bash
cp infra/gcp/terraform.tfvars.example infra/gcp/terraform.tfvars   # project_id, bucket_name
make gcp-bootstrap          # enables APIs and creates Artifact Registry
make gcp-deploy TAG=v1      # amd64 build + push + terraform apply
```

Creates: a bucket with Nearline/Coldline lifecycle for raw; Artifact Registry with
cleanup; Cloud Run (`min=0`, `max=1`, concurrency 1, CPU only during requests); a GCS
notification filtered by prefix → Pub/Sub → push authenticated with OIDC; HMAC keys in
Secret Manager so DuckDB can access GCS; dead-letter topic and Monitoring alerts; an
optional budget.

## Alerts

| | AWS | GCP |
|---|---|---|
| Failure after retries | Lambda `on_failure` destination → SNS (includes the event and the error) | Pub/Sub dead-letter after `max_delivery_attempts` (5) → Monitoring alert |
| Any error | `Errors ≥ 1` alarm | Alert on Cloud Run 5xx responses |
| Close to the time limit | Alarm: duration > 80 % of the timeout (15 min) | — |
| Day not delivered or not processed | Daily freshness check → error → SNS | Daily freshness check → 5xx → alert |

Set `alert_email` in `terraform.tfvars`. On AWS you have to confirm the subscription
from the email SNS sends. On GCP, failed messages stay in the `<name>-markers-dlq`
subscription for 7 days so you can inspect or replay them.

Every retry runs dbt again. To avoid paying for pointless retries on a permanent
error, lower `max_delivery_attempts` (GCP) or `maximum_retry_attempts` (AWS).

## FinOps levers included

- **Scale-to-zero**: no traffic, no billed compute (Lambda per invocation; Cloud Run
  with `min_instance_count = 0` and `cpu_idle = true`).
- **Partition pruning**: each run reads and writes a single day in bronze/silver.
- **Event filtering at the source**: only the `_SUCCESS` marker wakes up compute. The
  pipeline's own writes don't cause invocations.
- **Columnar Parquet** in bronze/silver/gold, much cheaper to scan than JSON.
- **Storage lifecycle**: raw and bronze move to colder classes over time. On S3 only
  objects >128 KB are transitioned, because IA/Glacier IR bill that minimum per object
  and moving small files costs more.
- **Arm64 (Graviton)** on Lambda; bounded log and image retention.
- **Budgets** alerting at 80 % (forecast) and 100 % (actual), filtered by the
  `project` tag. On AWS it must be activated as a *cost allocation tag*.

## Known limits and decisions

- **One day at a time**: concurrency 1 on both clouds so two runs never write the same
  Gold partitions at once. New AWS accounts (limit of 10) can't reserve concurrency:
  use `reserved_concurrency = -1`.
- **Max time**: 15 min on Lambda. On GCP the Pub/Sub *ack deadline* is 10 min: if a
  build takes longer, the message is redelivered (idempotent, but it costs). For long
  workloads, Cloud Run Jobs is a better fit.
- **Days without data**: a marker without orders fails the build on purpose (volume
  test and contract), because `dbt-duckdb` would write a row of NULLs instead of an
  empty file. If your business legitimately has days with no sales, disable that test
  or don't write the marker on those days.
- **Secrets**: the GCS HMAC secret ends up in the Terraform state. Use an encrypted
  remote backend (see `versions.tf`).

## CI

`.github/workflows/ci.yml` runs on every push to `main` and on every PR:

- `ruff` and `pytest` (including the end-to-end pipeline).
- `terraform fmt -check` and `terraform validate` for AWS and GCP.
- Build of the Lambda image on arm64 (the production one).
- Build of both images on amd64 and `scripts/smoke_images.sh`: it invokes the Lambda
  through its emulator and sends Cloud Run a simulated Pub/Sub message.

`.github/workflows/pages.yml` publishes the demo to GitHub Pages (requires
*Settings → Pages → Source: GitHub Actions*).

## Layout

```
src/lakehouse/        CLI, generator, dbt runner, metrics and handlers (aws_lambda, gcp_cloud_run)
dbt/                  dbt project (profiles.yml included, local/aws/gcp targets)
  macros/lake.sql     lake paths, partition filter, deduplication
infra/aws, infra/gcp  Terraform per cloud
tests/                pytest (events/partitions + e2e against a temporary lake)
scripts/              image smoke test and site data export
site/index.html       static dashboard (DuckDB-WASM)
docs/                 architecture diagram
```

Code comments and dbt docs are in Spanish.

## License

[MIT](LICENSE)
