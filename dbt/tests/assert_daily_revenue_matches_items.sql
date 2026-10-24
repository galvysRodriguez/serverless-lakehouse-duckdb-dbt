-- Conciliación: el ingreso diario debe igualar la suma de líneas de pedidos no cancelados.
with expected as (
    select o.order_date, sum(i.line_total) as revenue
    from {{ ref('int_order_items_current') }} as i
    inner join {{ ref('int_orders_current') }} as o using (order_id)
    where o.status <> 'cancelled'
    group by o.order_date
)

select d.order_date, d.gross_revenue, e.revenue
from {{ ref('gld_daily_sales') }} as d
left join expected as e using (order_date)
where abs(d.gross_revenue - coalesce(e.revenue, 0)) > 0.01
