with latest as (
    select *
    from {{ ref('brz_orders') }}
    where {{ partition_filter() }}
    {{ latest_by('order_id, year, month, day', 'updated_at desc, _loaded_at desc') }}
),

items as (
    select
        order_id,
        cast(created_at as date) as order_date,
        updated_at,
        year,
        month,
        day,
        unnest(items) as item
    from latest
)

select
    order_id,
    item.line_number as line_number,
    item.product_id as product_id,
    item.quantity as quantity,
    cast(item.unit_price as decimal(12, 2)) as unit_price,
    cast(item.quantity * item.unit_price as decimal(12, 2)) as line_total,
    order_date,
    updated_at,
    year,
    month,
    day
from items
