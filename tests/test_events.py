import base64
import json
from datetime import date

from lakehouse.events import dates_from_pubsub_push, dates_from_s3_event
from lakehouse.partitions import date_from_key, hive_path, marker_key, run_date_from_marker

D = date(2026, 10, 3)


def test_hive_path_matches_duckdb_partition_format():
    assert hive_path(D) == "year=2026/month=10/day=3"


def test_date_from_key_accepts_zero_padded_and_rejects_invalid():
    assert date_from_key("raw/x/year=2026/month=01/day=09/f.json") == date(2026, 1, 9)
    assert date_from_key("raw/x/year=2026/month=02/day=30/f.json") is None
    assert date_from_key("gold/daily_sales.parquet") is None


def test_only_markers_trigger_a_run():
    assert run_date_from_marker(marker_key(D)) == D
    assert run_date_from_marker(f"raw/ecommerce/orders/{hive_path(D)}/orders.json") is None
    assert run_date_from_marker(f"silver/orders/{hive_path(D)}/_SUCCESS") is None


def test_s3_event_decodes_keys_and_dedupes_dates():
    key = marker_key(D).replace("=", "%3D")
    record = {"s3": {"object": {"key": key}}}
    other = {"s3": {"object": {"key": "raw/ecommerce/orders/x.json"}}}
    assert dates_from_s3_event({"Records": [record, other, record]}) == [D]


def test_manual_invocation():
    assert dates_from_s3_event({"run_date": "2026-10-03"}) == [D]
    assert dates_from_pubsub_push({"run_date": "2026-10-03"}) == [D]


def test_pubsub_push_from_attributes_or_data():
    by_attr = {"message": {"attributes": {"objectId": marker_key(D)}}}
    data = base64.b64encode(json.dumps({"name": marker_key(D)}).encode()).decode()
    by_data = {"message": {"data": data}}
    assert dates_from_pubsub_push(by_attr) == [D]
    assert dates_from_pubsub_push(by_data) == [D]
    assert dates_from_pubsub_push({"message": {"attributes": {"objectId": "gold/x"}}}) == []
