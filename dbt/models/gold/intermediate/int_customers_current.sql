select *
from {{ ref('slv_customers') }}
where customer_id is not null
{{ latest_by('customer_id', 'updated_at desc') }}
