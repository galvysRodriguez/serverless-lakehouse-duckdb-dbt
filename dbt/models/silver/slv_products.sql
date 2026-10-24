select
    product_id,
    trim(name) as name,
    lower(trim(category)) as category,
    cast(price as decimal(12, 2)) as price,
    updated_at,
    year,
    month,
    day
from {{ ref('brz_products') }}
where {{ partition_filter() }}
{{ latest_by('product_id, year, month, day', 'updated_at desc, _loaded_at desc') }}
