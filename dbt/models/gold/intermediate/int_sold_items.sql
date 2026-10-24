-- Líneas de pedidos no cancelados, con el cliente y el mes del pedido.
select
    i.order_id,
    i.product_id,
    i.quantity,
    i.line_total,
    o.customer_id,
    o.order_date
from {{ ref('int_order_items_current') }} as i
inner join {{ ref('int_orders_current') }} as o using (order_id)
where o.status <> 'cancelled'
