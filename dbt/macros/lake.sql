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

{#- ---------------------------------------------------------------------------
    Gold incremental por mes.

    Un día de datos solo puede cambiar los meses de creación de los pedidos que
    llegaron ese día (altas y cambios de estado). Gold recalcula esos meses y deja
    el resto de particiones intactas.
--------------------------------------------------------------------------- -#}

{#- Lista de (año, mes) a recalcular. Siempre incluye el mes de run_date, así un día
    sin pedidos no produce un modelo vacío. Con full_scan devuelve none (= todos). -#}
{% macro affected_months(orders_relation) -%}
  {%- if var('full_scan') -%}
    {{- return(none) -}}
  {%- endif -%}
  {%- set d = run_date() -%}
  {%- set months = [(d.year, d.month)] -%}
  {%- if execute -%}
    {%- set result = run_query(
          "select distinct year(order_date), month(order_date) from " ~ orders_relation
          ~ " where order_id is not null and " ~ partition_filter()) -%}
    {%- for row in result.rows -%}
      {%- if (row[0], row[1]) not in months -%}
        {%- do months.append((row[0], row[1])) -%}
      {%- endif -%}
    {%- endfor -%}
  {%- endif -%}
  {{- return(months | sort) -}}
{%- endmacro %}

{#- Particiones de silver que pueden tener versiones de pedidos creados en esos meses:
    todo lo que llegó desde el primer día del mes más antiguo (las versiones siempre
    llegan después de la creación). DuckDB poda el resto de archivos. -#}
{% macro arrival_window(months) -%}
  {%- if months is none -%}
    true
  {%- else -%}
    {%- set y, m = months[0] -%}
    (year > {{ y }} or (year = {{ y }} and month >= {{ m }}))
  {%- endif -%}
{%- endmacro %}

{% macro in_months(date_column, months) -%}
  {%- if months is none -%}
    true
  {%- else -%}
    date_trunc('month', {{ date_column }}) in (
      {%- for y, m in months -%}
        date '{{ "%04d-%02d-01" % (y, m) }}'{{ ", " if not loop.last }}
      {%- endfor -%}
    )
  {%- endif -%}
{%- endmacro %}

{#- true si el modelo ya tiene archivos en el lago (el hook on-run-start registró su
    vista). Permite a una dimensión leer su versión anterior y fusionar solo lo nuevo. -#}
{% macro self_exists() -%}
  {{- return(execute and load_relation(this) is not none) -}}
{%- endmacro %}
