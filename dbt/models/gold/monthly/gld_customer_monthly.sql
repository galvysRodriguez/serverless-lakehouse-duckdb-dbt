-- Agregado cliente x mes. gld_customer_ltv lo suma en vez de releer silver entero.
select
    customer_id,
    cast(date_trunc('month', order_date) as date) as order_month,
    min(order_date) as first_order_date,
    max(order_date) as last_order_date,
    count(*) as orders_count,
    cast(sum(order_total) as decimal(14, 2)) as revenue,
    year(order_month) as year,
    month(order_month) as month
from {{ ref('int_orders_current') }}
where status <> 'cancelled'
group by all
