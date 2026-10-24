select *
from {{ ref('slv_products') }}
where product_id is not null
{{ latest_by('product_id', 'updated_at desc') }}
