-- Gold: ventas por día de creación del pedido. Los cancelados cuentan como
-- pedidos pero no suman ingresos.
with orders as (
    select * from {{ ref('int_orders_current') }}
),

items as (
    select i.order_id, i.quantity
    from {{ ref('int_order_items_current') }} as i
    inner join orders as o using (order_id)
    where o.status <> 'cancelled'
),

units as (
    select order_id, sum(quantity) as units
    from items
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
        as avg_order_value
from orders as o
left join units as u using (order_id)
group by o.order_date
order by o.order_date
