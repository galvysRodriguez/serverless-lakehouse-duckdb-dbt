with per_product as (
    select
        product_id,
        sum(orders_count) as orders_count,
        sum(units_sold) as units_sold,
        sum(revenue) as revenue
    from {{ ref('gld_product_monthly') }}
    where product_id is not null
    group by product_id
)

select
    p.product_id,
    p.name,
    p.category,
    p.price as current_price,
    cast(coalesce(s.orders_count, 0) as bigint) as orders_count,
    cast(coalesce(s.units_sold, 0) as bigint) as units_sold,
    cast(coalesce(s.revenue, 0) as decimal(14, 2)) as revenue,
    rank() over (order by coalesce(s.revenue, 0) desc) as revenue_rank
from {{ ref('gld_dim_products') }} as p
left join per_product as s using (product_id)
