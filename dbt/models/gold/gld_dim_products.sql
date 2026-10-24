with changes as (
    select product_id, name, category, price, updated_at
    from {{ ref('slv_products') }}
    where product_id is not null and {{ partition_filter() }}
)

{%- if self_exists() %},

previous as (
    select product_id, name, category, price, updated_at
    from {{ this }}
)
{%- endif %}

select *
from (
    select * from changes
    {%- if self_exists() %}
    union all
    select * from previous
    {%- endif %}
)
{{ latest_by('product_id', 'updated_at desc') }}
