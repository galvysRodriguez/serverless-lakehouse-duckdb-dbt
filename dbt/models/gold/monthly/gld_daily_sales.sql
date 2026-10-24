-- Gold: ventas por día de creación del pedido. Los cancelados cuentan como
-- pedidos pero no suman ingresos. Solo se reescriben los meses afectados.
with orders as (
    select * from {{ ref('int_orders_current') }}
),

units as (
    select order_id, sum(quantity) as units
    from {{ ref('int_sold_items') }}
    group by order_id
)

select
    o.order_date,
    count(*) as orders_count,
    count(*) filter (where o.status = 'cancelled') as cancelled_count,
    count(distinct o.customer_id) as unique_customers,
    cast(coalesce(sum(u.units), 0) as bigint) as units_sold,
    cast(coalesce(sum(o.order_total) filter (where o.status <> 'cancelled'), 0) as decimal(14, 2))
        as gross_revenue,
    cast(avg(o.order_total) filter (where o.status <> 'cancelled') as decimal(12, 2))
        as avg_order_value,
    year(o.order_date) as year,
    month(o.order_date) as month
from orders as o
left join units as u using (order_id)
group by o.order_date
