{#-
  Create or update a materialized view in ClickHouse.
  This involves creating both the materialized view itself and a
  target table that the materialized view writes to.
-#}
{%- materialization materialized_view, adapter='clickhouse' -%}

  {%- set target_relation = this.incorporate(type='table') -%}
  {%- set cluster_clause = on_cluster_clause(target_relation) -%}

  {# look for an existing relation for the target table and create backup relations if necessary #}
  {%- set existing_relation = load_cached_relation(this) -%}
  {%- set backup_relation = none -%}
  {%- set preexisting_backup_relation = none -%}
  {%- set preexisting_intermediate_relation = none -%}
  {% if existing_relation is not none %}
    {%- set backup_relation_type = existing_relation.type -%}
    {%- set backup_relation = make_backup_relation(target_relation, backup_relation_type) -%}
    {%- set preexisting_backup_relation = load_cached_relation(backup_relation) -%}
    {% if not existing_relation.can_exchange %}
      {%- set intermediate_relation =  make_intermediate_relation(target_relation) -%}
      {%- set preexisting_intermediate_relation = load_cached_relation(intermediate_relation) -%}
    {% endif %}
  {% endif %}

  {% set grant_config = config.get('grants') %}

  {{ run_hooks(pre_hooks, inside_transaction=False) }}

  -- drop the temp relations if they exist already in the database
  {{ drop_relation_if_exists(preexisting_intermediate_relation) }}
  {{ drop_relation_if_exists(preexisting_backup_relation) }}

  -- `BEGIN` happens here:
  {{ run_hooks(pre_hooks, inside_transaction=True) }}

  -- extract the names of the materialized views from the sql
  {% set view_names = modules.re.findall('--([^:]+):begin', sql) %}

  -- extract the sql for each of the materialized view into a map
  {% set views = {} %}
  {% if view_names %}
    {% for view_name in view_names %}
      {% set view_sql = modules.re.findall('--' + view_name + ':begin(.*)--' + view_name + ':end', sql, flags=modules.re.DOTALL)[0] %}
      {%- set _ = views.update({view_name: view_sql}) -%}
    {% endfor %}
  {% else %}
    {%- set _ = views.update({"mv": sql}) -%}
  {% endif %}

  {% if backup_relation is none %}
    {{ log('Creating new materialized view ' + target_relation.name )}}
    {% set catchup_data = config.get("catchup", True) %}
    {{ clickhouse__get_create_materialized_view_as_sql(target_relation, sql, views, catchup_data) }}
  {% elif existing_relation.can_exchange %}
    {{ log('Replacing existing materialized view ' + target_relation.name) }}
    -- in this section, we look for mvs that has the same pattern as this model, but for some reason,
    -- are not listed in the model. This might happen when using multiple mv, and renaming one of the mv in the model.
    -- In case such mv found, we raise a warning to the user, that they might need to drop the mv manually.
    {{ log('Searching for existing materialized views with the pattern of ' + target_relation.name) }}
    {{ log('Views dictionary contents: ' + views | string) }}

        {% set tables_query %}
            select table_name
            from information_schema.tables
            where table_schema = '{{ existing_relation.schema }}'
              and table_name like '%{{ target_relation.name }}%'
              and table_type = 'VIEW'
        {% endset %}

    {% set tables_result = run_query(tables_query) %}
    {% if tables_result is not none and tables_result.columns %}
        {% set tables = tables_result.columns[0].values() %}
        {{ log('Current mvs found in ClickHouse are: ' + tables | join(', ')) }}
        {% set mv_names = [] %}
        {% for key in views.keys() %}
            {% do mv_names.append(target_relation.name ~ "_" ~ key) %}
        {% endfor %}
        {{ log('Model mvs to replace ' + mv_names | string) }}
        {% for table in tables %}
            {% if table not in mv_names %}
                {{ log('Warning - Table "' + table + '" was detected with the same pattern as model name "' + target_relation.name + '" but was not found in this run. In case it is a renamed mv that was previously part of this model, drop it manually (!!!)') }}
            {% endif %}
        {% endfor %}
    {% else %}
        {{ log('No existing mvs found matching the pattern. continuing..', info=True) }}
    {% endif %}
    {{ clickhouse__drop_mvs(target_relation, cluster_clause, views) }}
    {% if should_full_refresh() %}
      {% call statement('main') -%}
        {{ get_create_table_as_sql(False, backup_relation, sql) }}
      {%- endcall %}
      {% do exchange_tables_atomic(backup_relation, existing_relation) %}
    {% else %}
      -- we need to have a 'main' statement
      {% call statement('main') -%}
        select 1
      {%- endcall %}
    {% endif %}
    {{ clickhouse__create_mvs(existing_relation, cluster_clause, views) }}
  {% else %}
    {{ log('Replacing existing materialized view ' + target_relation.name) }}
    {{ clickhouse__replace_mv(target_relation, existing_relation, intermediate_relation, backup_relation, sql, views) }}
  {% endif %}

  -- cleanup
  {% set should_revoke = should_revoke(existing_relation, full_refresh_mode=True) %}
  {% do apply_grants(target_relation, grant_config, should_revoke=should_revoke) %}

  {% do persist_docs(target_relation, model) %}

  {{ run_hooks(post_hooks, inside_transaction=True) }}

  {{ adapter.commit() }}

  {{ drop_relation_if_exists(backup_relation) }}

  {{ run_hooks(post_hooks, inside_transaction=False) }}

  {% set relations = [target_relation] %}
  {% for view in views %}
    {{ relations.append(target_relation.derivative('_' + view, 'materialized_view')) }}
  {% endfor %}

  {{ return({'relations': relations}) }}

{%- endmaterialization -%}


{#
  There are two steps to creating a materialized view:
  1. Create a new table based on the SQL in the model
  2. Create a materialized view using the SQL in the model that inserts
  data into the table creating during step 1
#}
{% macro clickhouse__get_create_materialized_view_as_sql(relation, sql, views, catchup=True ) -%}
  {% call statement('main') %}
  {% if catchup == True %}
    {{ get_create_table_as_sql(False, relation, sql) }}
  {% else %}
  {{ log('Catchup data config was set to false, skipping mv-target-table initial insertion ')}}
   {% set has_contract = config.get('contract').enforced %}
    {{ create_table_or_empty(False, relation, sql, has_contract) }}
  {% endif %}
  {% endcall %}
  {%- set cluster_clause = on_cluster_clause(relation) -%}
  {%- set mv_relation = relation.derivative('_mv', 'materialized_view') -%}
  {{ clickhouse__create_mvs(relation, cluster_clause, views) }}
{%- endmacro %}

{% macro clickhouse__drop_mv(mv_relation, cluster_clause)  -%}
    drop view if exists {{ mv_relation }} {{ cluster_clause }}
{%- endmacro %}u

{% macro clickhouse__create_mv(mv_relation, target_table, cluster_clause, sql)  -%}
  create materialized view if not exists {{ mv_relation }} {{ cluster_clause }}
  to {{ target_table }}
  as {{ sql }}
{%- endmacro %}

{% macro clickhouse__drop_mvs(target_relation, cluster_clause, views)  -%}
    {% for view in views.keys() %}
      {%- set mv_relation = target_relation.derivative('_' + view, 'materialized_view') -%}
      {% call statement('drop existing mv: ' + view) -%}
        {{ clickhouse__drop_mv(mv_relation, cluster_clause) }};
      {% endcall %}
    {% endfor %}
{%- endmacro %}

{% macro clickhouse__create_mvs(target_relation, cluster_clause, views)  -%}
    {% for view, view_sql in views.items() %}
      {%- set mv_relation = target_relation.derivative('_' + view, 'materialized_view') -%}
      {% call statement('create existing mv: ' + view) -%}
        {{ clickhouse__create_mv(mv_relation, target_relation, cluster_clause, view_sql) }};
      {% endcall %}
    {% endfor %}
{%- endmacro %}

{% macro clickhouse__replace_mv(target_relation, existing_relation, intermediate_relation, backup_relation, sql, views) %}
  {# drop existing materialized view while we recreate the target table #}
  {%- set cluster_clause = on_cluster_clause(target_relation) -%}
  {{ clickhouse__drop_mvs(target_relation, cluster_clause, views) }}

  {# recreate the target table #}
  {% call statement('main') -%}
    {{ get_create_table_as_sql(False, intermediate_relation, sql) }}
  {%- endcall %}
  {{ adapter.rename_relation(existing_relation, backup_relation) }}
  {{ adapter.rename_relation(intermediate_relation, target_relation) }}

  {# now that the target table is recreated, we can finally create our new view #}
  {{ clickhouse__create_mvs(target_relation, cluster_clause, views) }}
{% endmacro %}

