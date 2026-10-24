select
    product_id,
    cast(date_trunc('month', order_date) as date) as order_month,
    count(distinct order_id) as orders_count,
    cast(sum(quantity) as bigint) as units_sold,
    cast(sum(line_total) as decimal(14, 2)) as revenue,
    year(order_month) as year,
    month(order_month) as month
from {{ ref('int_sold_items') }}
group by all
