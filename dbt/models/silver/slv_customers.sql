select
    customer_id,
    trim(full_name) as full_name,
    lower(trim(email)) as email,
    upper(trim(country)) as country,
    created_at,
    updated_at,
    year,
    month,
    day
from {{ ref('brz_customers') }}
where {{ partition_filter() }}
{{ latest_by('customer_id', 'updated_at desc, _loaded_at desc') }}
