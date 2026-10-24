"""Generador de datos e-commerce sintéticos para la capa raw.

Por cada día escribe tres feeds NDJSON con particionamiento Hive y, al final, un
marcador ``_SUCCESS`` que dispara el pipeline:

    raw/ecommerce/orders/year=2026/month=10/day=23/orders.json
    raw/ecommerce/customers/year=2026/month=10/day=23/customers.json
    raw/ecommerce/products/year=2026/month=10/day=23/products.json
    raw/ecommerce/_markers/year=2026/month=10/day=23/_SUCCESS

Es determinista (misma fecha -> mismos datos), así un pedido creado el día D puede
reaparecer en los feeds de D+1 y D+2 con su nuevo estado, como en un CDC real.
También inyecta problemas de calidad (duplicados, mayúsculas, espacios) para que la
capa Silver tenga algo que limpiar.
"""

from __future__ import annotations

import hashlib
import json
import random
import tempfile
from datetime import date, datetime, time, timedelta
from pathlib import Path

from lakehouse.config import Settings
from lakehouse.duck import connect
from lakehouse.partitions import RAW_PREFIX, hive_path, marker_key

CATEGORIES = ["electronics", "home", "fashion", "sports", "books", "beauty", "toys", "grocery"]
COUNTRIES = ["AR", "BR", "CL", "CO", "ES", "MX", "PE", "US", "UY"]
N_PRODUCTS = 40
N_CUSTOMERS = 2000


def _rng(*parts: object) -> random.Random:
    seed = hashlib.sha256("|".join(map(str, parts)).encode()).hexdigest()
    return random.Random(int(seed[:16], 16))


def _ts(d: date, rng: random.Random) -> datetime:
    return datetime.combine(d, time()) + timedelta(seconds=rng.randrange(86_400))


def product_price(product_id: str, d: date) -> float:
    base = _rng("product", product_id).uniform(5, 500)
    # Variación semanal de precio, estable dentro de la misma semana ISO.
    week = d.isocalendar()
    drift = _rng("price", product_id, week.year, week.week).uniform(0.9, 1.1)
    return round(base * drift, 2)


def products_for_day(d: date) -> list[dict]:
    rows = []
    for i in range(1, N_PRODUCTS + 1):
        pid = f"P{i:03d}"
        rng = _rng("product", pid)
        rows.append(
            {
                "product_id": pid,
                "name": f"Producto {i:03d}",
                "category": rng.choice(CATEGORIES),
                "price": product_price(pid, d),
                "updated_at": datetime.combine(d, time()).isoformat(),
            }
        )
    return rows


def customer_record(customer_id: str, d: date) -> dict:
    rng = _rng("customer", customer_id)
    n = int(customer_id[1:])
    email = f"cliente{n}@example.com"
    # Ruido intencional: algunos sistemas origen mandan el email sin normalizar.
    if _rng("email-noise", customer_id, d).random() < 0.1:
        email = f"  {email.upper()} "
    return {
        "customer_id": customer_id,
        "full_name": f"Cliente {n}",
        "email": email,
        "country": rng.choice(COUNTRIES),
        "created_at": (datetime(2025, 1, 1) + timedelta(days=rng.randrange(365))).isoformat(),
        "updated_at": _ts(d, _rng("customer-ts", customer_id, d)).isoformat(),
    }


def _new_orders(d: date) -> list[dict]:
    rng = _rng("orders", d)
    orders = []
    for i in range(rng.randint(150, 250)):
        order_id = f"O{d:%Y%m%d}-{i:04d}"
        orng = _rng("order", order_id)
        created = _ts(d, orng)
        items = []
        for line, pid in enumerate(orng.sample(range(1, N_PRODUCTS + 1), orng.randint(1, 4)), 1):
            product_id = f"P{pid:03d}"
            items.append(
                {
                    "line_number": line,
                    "product_id": product_id,
                    "quantity": orng.randint(1, 3),
                    "unit_price": product_price(product_id, d),
                }
            )
        orders.append(
            {
                "order_id": order_id,
                "customer_id": f"C{orng.randint(1, N_CUSTOMERS):05d}",
                "status": "placed",
                "created_at": created.isoformat(),
                "updated_at": created.isoformat(),
                "items": items,
            }
        )
    return orders


def _status_on(order: dict, created_day: date, d: date) -> str | None:
    """Nuevo estado del pedido en el día ``d`` o ``None`` si ese día no cambió."""
    age = (d - created_day).days
    rng = _rng("lifecycle", order["order_id"])
    cancelled = rng.random() < 0.05
    if age == 1:
        return "cancelled" if cancelled else "shipped"
    if age == 2 and not cancelled and rng.random() < 0.9:
        return "delivered"
    return None


def orders_for_day(d: date) -> list[dict]:
    feed = _new_orders(d)
    for back in (1, 2):
        prev_day = d - timedelta(days=back)
        for order in _new_orders(prev_day):
            status = _status_on(order, prev_day, d)
            if status:
                updated = _ts(d, _rng("update", order["order_id"], d))
                feed.append({**order, "status": status, "updated_at": updated.isoformat()})

    rng = _rng("dq", d)
    for order in feed:
        # Ruido intencional en el estado: mayúsculas y espacios.
        if rng.random() < 0.05:
            order["status"] = f" {order['status'].upper()}"
    # ~2 % de registros duplicados (reintentos del productor).
    feed.extend(dict(o) for o in rng.sample(feed, k=max(1, len(feed) // 50)))
    return feed


def customers_for_day(d: date, orders: list[dict]) -> list[dict]:
    ids = sorted({o["customer_id"] for o in orders})
    return [customer_record(cid, d) for cid in ids]


def generate_day(settings: Settings, d: date) -> dict[str, int]:
    orders = orders_for_day(d)
    feeds = {
        "orders": orders,
        "customers": customers_for_day(d, orders),
        "products": products_for_day(d),
    }
    con = connect(settings)
    with tempfile.TemporaryDirectory() as tmp:
        for entity, rows in feeds.items():
            local = Path(tmp) / f"{entity}.json"
            local.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
            dest = f"{settings.lake_root}/{RAW_PREFIX}/{entity}/{hive_path(d)}/{entity}.json"
            _ensure_parent(settings, dest)
            # DuckDB sube el archivo al bucket con las mismas credenciales que usa dbt.
            con.execute(
                f"COPY (SELECT * FROM read_json('{local}', format='newline_delimited')) "
                f"TO '{dest}' (FORMAT json)"
            )
        marker = f"{settings.lake_root}/{marker_key(d)}"
        _ensure_parent(settings, marker)
        con.execute(f"COPY (SELECT '{d.isoformat()}' AS run_date) TO '{marker}' (FORMAT csv)")
    con.close()
    return {entity: len(rows) for entity, rows in feeds.items()}


def _ensure_parent(settings: Settings, path: str) -> None:
    if settings.scheme == "local":
        Path(path).parent.mkdir(parents=True, exist_ok=True)
