-- Conciliación de los meses recalculados en esta ejecución: el ingreso diario debe
-- igualar la suma de líneas de pedidos no cancelados.
{%- set months = affected_months(ref('slv_orders')) %}

with expected as (
    select order_date, sum(line_total) as revenue
    from {{ ref('int_sold_items') }}
    group by order_date
),

actual as (
    select order_date, gross_revenue
    from {{ ref('gld_daily_sales') }}
    where {{ in_months('order_date', months) }}
)

select a.order_date, a.gross_revenue, e.revenue
from actual as a
full outer join expected as e using (order_date)
where abs(coalesce(a.gross_revenue, 0) - coalesce(e.revenue, 0)) > 0.01
