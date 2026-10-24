select
    customer_id,
    full_name,
    email,
    country,
    created_at,
    updated_at,
    filename as _source_file,
    current_timestamp as _loaded_at,
    year,
    month,
    day
from read_json(
    '{{ raw_path("customers") }}',
    format = 'newline_delimited',
    hive_partitioning = true,
    hive_types = {'year': 'INTEGER', 'month': 'INTEGER', 'day': 'INTEGER'},
    filename = true,
    columns = {
        'customer_id': 'VARCHAR',
        'full_name': 'VARCHAR',
        'email': 'VARCHAR',
        'country': 'VARCHAR',
        'created_at': 'TIMESTAMP',
        'updated_at': 'TIMESTAMP'
    }
)
where {{ partition_filter() }}
