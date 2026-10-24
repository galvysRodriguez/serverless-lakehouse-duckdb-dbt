{%- set months = affected_months(ref('slv_orders')) %}

select *
from {{ ref('slv_order_items') }}
where order_id is not null
    and {{ arrival_window(months) }}
    and {{ in_months('order_date', months) }}
{{ latest_by('order_id, line_number', 'updated_at desc') }}
