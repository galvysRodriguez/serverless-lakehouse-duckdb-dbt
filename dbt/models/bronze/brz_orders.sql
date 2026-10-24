-- Bronze: copia fiel del feed raw del día, tipada y con metadatos de carga.
-- Lee solo la partición de run_date gracias al filtro sobre year/month/day.
select
    order_id,
    customer_id,
    status,
    created_at,
    updated_at,
    items,
    filename as _source_file,
    current_timestamp as _loaded_at,
    year,
    month,
    day
from read_json(
    '{{ raw_path("orders") }}',
    format = 'newline_delimited',
    hive_partitioning = true,
    hive_types = {'year': 'INTEGER', 'month': 'INTEGER', 'day': 'INTEGER'},
    filename = true,
    columns = {
        'order_id': 'VARCHAR',
        'customer_id': 'VARCHAR',
        'status': 'VARCHAR',
        'created_at': 'TIMESTAMP',
        'updated_at': 'TIMESTAMP',
        'items': 'STRUCT(line_number INTEGER, product_id VARCHAR, quantity INTEGER, unit_price DOUBLE)[]'
    }
)
where {{ partition_filter() }}
