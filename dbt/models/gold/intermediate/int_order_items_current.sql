select *
from {{ ref('slv_order_items') }}
where order_id is not null
{{ latest_by('order_id, line_number', 'updated_at desc') }}
