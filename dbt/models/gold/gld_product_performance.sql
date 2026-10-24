with sold as (
    select i.product_id, i.order_id, i.quantity, i.line_total
    from {{ ref('int_order_items_current') }} as i
    inner join {{ ref('int_orders_current') }} as o using (order_id)
    where o.status <> 'cancelled'
),

per_product as (
    select
        product_id,
        count(distinct order_id) as orders_count,
        sum(quantity) as units_sold,
        sum(line_total) as revenue
    from sold
    group by product_id
)

select
    p.product_id,
    p.name,
    p.category,
    p.price as current_price,
    coalesce(s.orders_count, 0) as orders_count,
    coalesce(s.units_sold, 0) as units_sold,
    cast(coalesce(s.revenue, 0) as decimal(14, 2)) as revenue,
    rank() over (order by coalesce(s.revenue, 0) desc) as revenue_rank
from {{ ref('int_products_current') }} as p
left join per_product as s using (product_id)
