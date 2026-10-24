-- Dentro de una misma partición diaria no puede haber dos versiones de un pedido.
select order_id, year, month, day, count(*) as n
from {{ ref('slv_orders') }}
where {{ partition_filter() }}
group by all
having count(*) > 1
