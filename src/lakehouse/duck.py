"""Conexión DuckDB configurada para el mismo almacenamiento que usa dbt."""

from __future__ import annotations

import os

import duckdb

from lakehouse.config import Settings


def connect(settings: Settings) -> duckdb.DuckDBPyConnection:
    config = {}
    if ext_dir := os.environ.get("DUCKDB_EXTENSION_DIRECTORY"):
        config["extension_directory"] = ext_dir
    con = duckdb.connect(":memory:", config=config)

    if settings.scheme == "s3":
        con.execute("INSTALL httpfs; LOAD httpfs; INSTALL aws; LOAD aws;")
        region = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
        con.execute(
            f"CREATE SECRET lake (TYPE s3, PROVIDER credential_chain, REGION {_quote(region)})"
        )
    elif settings.scheme == "gcs":
        con.execute("INSTALL httpfs; LOAD httpfs;")
        key_id = _quote(os.environ["GCS_HMAC_KEY_ID"])
        secret = _quote(os.environ["GCS_HMAC_SECRET"])
        con.execute(f"CREATE SECRET lake (TYPE gcs, KEY_ID {key_id}, SECRET {secret})")
    return con


def _quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"
