-- Estado vigente de los pedidos creados en los meses afectados por run_date.
-- `order_id is not null` descarta la fila placeholder que dbt-duckdb escribe
-- cuando un modelo external queda vacío.
{%- set months = affected_months(ref('slv_orders')) %}

select *
from {{ ref('slv_orders') }}
where order_id is not null
    and {{ arrival_window(months) }}
    and {{ in_months('order_date', months) }}
{{ latest_by('order_id', 'updated_at desc') }}
