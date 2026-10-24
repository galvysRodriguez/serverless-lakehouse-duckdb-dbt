{#- Raíz del lago: carpeta local, s3://bucket o gs://bucket. -#}
{% macro lake_root() -%}
  {{- env_var('LAKE_ROOT', 'data/lake').rstrip('/') -}}
{%- endmacro %}

{#- Glob de los archivos raw de una entidad: raw/ecommerce/<entity>/year=/month=/day=/*.json -#}
{% macro raw_path(entity) -%}
  {{- lake_root() }}/raw/ecommerce/{{ entity }}/*/*/*/*.json
{%- endmacro %}

{% macro run_date() -%}
  {%- set value = var('run_date') -%}
  {%- if value -%}
    {{- return(modules.datetime.date.fromisoformat(value | string)) -}}
  {%- else -%}
    {{- return(modules.datetime.datetime.utcnow().date()) -}}
  {%- endif -%}
{%- endmacro %}

{#- Filtro sobre columnas de partición Hive: DuckDB lo empuja al listado de archivos
    y solo lee la carpeta del día (partition pruning). -#}
{% macro partition_filter() -%}
  {%- if var('full_scan') -%}
    true
  {%- else -%}
    {%- set d = run_date() -%}
    (year = {{ d.year }} and month = {{ d.month }} and day = {{ d.day }})
  {%- endif -%}
{%- endmacro %}

{#- Se queda con la versión más reciente de cada clave. -#}
{% macro latest_by(key, order_by) -%}
  qualify row_number() over (partition by {{ key }} order by {{ order_by }}) = 1
{%- endmacro %}

{#- Sobrescribe la macro de dbt-duckdb: <lake>/<capa>/<entidad>[.parquet].
    El prefijo del modelo (brz_, slv_, gld_) se quita del nombre de la carpeta. -#}
{% macro external_location(relation, config) -%}
  {%- set entity = relation.identifier.split('_', 1)[1] -%}
  {%- set base = lake_root() ~ '/' ~ relation.schema ~ '/' ~ entity -%}
  {%- if config.get('options', {}).get('partition_by') is none -%}
    {{- base }}.{{ config.get('format', 'parquet') }}
  {%- else -%}
    {{- base -}}
  {%- endif -%}
{%- endmacro %}

{#- Usa el schema configurado tal cual (bronze/silver/gold) en vez de main_bronze. -#}
{% macro generate_schema_name(custom_schema_name, node) -%}
  {{- (custom_schema_name or target.schema) | trim -}}
{%- endmacro %}

{#- Los tests genéricos no pueden llamar macros propias en `where`, así que usan el
    marcador __run_partition__ (ver data_tests en dbt_project.yml) y aquí se expande. -#}
{% macro get_where_subquery(relation) -%}
  {%- set where = config.get('where') -%}
  {%- if where -%}
    {%- set where = where | replace('__run_partition__', partition_filter()) -%}
    {%- set filtered -%}
      (select * from {{ relation }} where {{ where }}) dbt_subquery
    {%- endset -%}
    {%- do return(filtered) -%}
  {%- else -%}
    {%- do return(relation) -%}
  {%- endif -%}
{%- endmacro %}

{#- on-run-start: la base es :memory:, así que al arrancar no existe ninguna vista.
    Registra una vista por cada modelo external que ya tenga archivos en el lago, para
    que `--select tag:gold` (o cualquier subconjunto) pueda leer capas que no se
    reconstruyen en esta ejecución. Cuesta un LIST por modelo. -#}
{% macro register_existing_external_models() -%}
  {%- if execute -%}
    {%- for node in graph.nodes.values()
          if node.resource_type == 'model' and node.config.materialized == 'external' -%}
      {%- set rel = api.Relation.create(database=target.database, schema=node.schema, identifier=node.alias) -%}
      {%- set options = node.config.get('options', {}) -%}
      {%- set location = external_location(rel, node.config) -%}
      {%- set read_location = adapter.external_read_location(location, options.copy()) -%}
      {%- set found = run_query("select count(*) from glob('" ~ read_location ~ "')").columns[0].values()[0] -%}
      {%- if found > 0 -%}
        {%- do run_query("create schema if not exists " ~ node.schema) -%}
        {%- do run_query(
              "create or replace view " ~ rel ~ " as select * from read_parquet('" ~ read_location
              ~ "', hive_partitioning = " ~ ('partition_by' in options) ~ ", union_by_name = true)") -%}
        {#- dbt cacheó las relaciones antes del hook: sin esto la materialización no ve la vista. -#}
        {%- do adapter.cache_added(rel.incorporate(type='view')) -%}
      {%- endif -%}
    {%- endfor -%}
  {%- endif -%}
  select 1
{%- endmacro %}
