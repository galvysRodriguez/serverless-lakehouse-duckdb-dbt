-- Estado vigente de cada pedido a través de todas las particiones de silver.
-- `order_id is not null` descarta la fila placeholder que dbt-duckdb escribe
-- cuando un modelo external queda vacío.
select *
from {{ ref('slv_orders') }}
where order_id is not null
{{ latest_by('order_id', 'updated_at desc') }}
