select
    product_id,
    name,
    category,
    price,
    updated_at,
    filename as _source_file,
    current_timestamp as _loaded_at,
    year,
    month,
    day
from read_json(
    '{{ raw_path("products") }}',
    format = 'newline_delimited',
    hive_partitioning = true,
    hive_types = {'year': 'INTEGER', 'month': 'INTEGER', 'day': 'INTEGER'},
    filename = true,
    columns = {
        'product_id': 'VARCHAR',
        'name': 'VARCHAR',
        'category': 'VARCHAR',
        'price': 'DOUBLE',
        'updated_at': 'TIMESTAMP'
    }
)
where {{ partition_filter() }}
