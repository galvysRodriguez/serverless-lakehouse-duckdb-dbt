-- Un marcador _SUCCESS sin pedidos en raw es una entrega rota del productor: se
-- falla en bronze antes de que Gold recalcule meses con datos incompletos.
{{ config(enabled=not var('full_scan')) }}

select count(*) as orders
from {{ ref('brz_orders') }}
where {{ partition_filter() }} and order_id is not null
having count(*) = 0
