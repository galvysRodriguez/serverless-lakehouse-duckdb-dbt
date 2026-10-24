with orders as (
    select * from {{ ref('int_orders_current') }}
    where status <> 'cancelled'
),

per_customer as (
    select
        customer_id,
        min(order_date) as first_order_date,
        max(order_date) as last_order_date,
        count(*) as orders_count,
        sum(order_total) as lifetime_revenue
    from orders
    group by customer_id
)

select
    p.customer_id,
    c.full_name,
    c.email,
    c.country,
    p.first_order_date,
    p.last_order_date,
    p.orders_count,
    cast(p.lifetime_revenue as decimal(14, 2)) as lifetime_revenue,
    cast(p.lifetime_revenue / p.orders_count as decimal(12, 2)) as avg_order_value,
    case
        when p.lifetime_revenue >= 2000 then 'vip'
        when p.lifetime_revenue >= 500 then 'regular'
        else 'ocasional'
    end as segment
from per_customer as p
left join {{ ref('int_customers_current') }} as c using (customer_id)
