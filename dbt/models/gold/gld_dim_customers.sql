-- Dimensión de clientes (SCD tipo 1): versión anterior + cambios del día.
-- Lee un archivo del tamaño de la dimensión y una partición de silver, no el histórico.
with changes as (
    select customer_id, full_name, email, country, created_at, updated_at
    from {{ ref('slv_customers') }}
    where customer_id is not null and {{ partition_filter() }}
)

{%- if self_exists() %},

previous as (
    select customer_id, full_name, email, country, created_at, updated_at
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
{{ latest_by('customer_id', 'updated_at desc') }}
