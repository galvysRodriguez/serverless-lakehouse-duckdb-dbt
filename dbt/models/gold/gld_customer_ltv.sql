-- Reescritura completa, pero sobre agregados mensuales (una fila por cliente y mes).
with per_customer as (
    select
        customer_id,
        min(first_order_date) as first_order_date,
        max(last_order_date) as last_order_date,
        sum(orders_count) as orders_count,
        sum(revenue) as lifetime_revenue
    from {{ ref('gld_customer_monthly') }}
    where customer_id is not null
    group by customer_id
)

select
    p.customer_id,
    c.full_name,
    c.email,
    c.country,
    p.first_order_date,
    p.last_order_date,
    cast(p.orders_count as bigint) as orders_count,
    cast(p.lifetime_revenue as decimal(14, 2)) as lifetime_revenue,
    cast(p.lifetime_revenue / p.orders_count as decimal(12, 2)) as avg_order_value,
    case
        when p.lifetime_revenue >= 2000 then 'vip'
        when p.lifetime_revenue >= 500 then 'regular'
        else 'ocasional'
    end as segment
from per_customer as p
left join {{ ref('gld_dim_customers') }} as c using (customer_id)
