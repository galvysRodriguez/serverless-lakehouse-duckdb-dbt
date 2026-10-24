-- Silver: pedidos del día limpios y deduplicados (una fila por pedido y partición).
-- Un pedido reaparece en días posteriores cuando cambia de estado; la versión
-- vigente se resuelve en gold/intermediate/int_orders_current.
select
    order_id,
    customer_id,
    lower(trim(status)) as status,
    created_at,
    updated_at,
    cast(created_at as date) as order_date,
    len(items) as item_count,
    cast(list_sum(list_transform(items, lambda i: i.quantity * i.unit_price)) as decimal(12, 2))
        as order_total,
    year,
    month,
    day
from {{ ref('brz_orders') }}
where {{ partition_filter() }}
{{ latest_by('order_id', 'updated_at desc, _loaded_at desc') }}
