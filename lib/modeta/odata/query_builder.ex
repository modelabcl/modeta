defmodule Modeta.OData.QueryBuilder do
  @moduledoc """
  Builds SQL queries from OData system query options.

  This module handles the construction of SQL queries based on OData v4 system
  query options like $filter, $select, $expand, $orderby, and pagination.

  Extracted from ModetaWeb.ODataController to separate domain logic from web logic.
  """

  alias Modeta.{Collections, Cache}
  alias Modeta.RelationshipDiscovery

  @doc """
  Builds a complete SQL query with all OData options applied.

  Takes a base query and applies the following transformations in order:
  1. $expand (LEFT JOINs for navigation properties)
  2. $select (column filtering)
  3. $filter (WHERE clauses)
  4. $orderby (ORDER BY clauses)
  5. Pagination (LIMIT/OFFSET)

  ## Parameters
  - base_query: The initial SQL query string
  - group_name: Collection group name for schema resolution
  - collection_name: Name of the collection being queried
  - filter_param: $filter parameter value
  - expand_param: $expand parameter value
  - select_param: $select parameter value
  - orderby_param: $orderby parameter value
  - skip_param: $skip parameter value
  - top_param: $top parameter value

  ## Returns
  - String containing the final SQL query with all options applied
  """
  def build_query_with_options(
        base_query,
        group_name,
        collection_name,
        filter_param,
        expand_param,
        select_param,
        orderby_param,
        skip_param,
        top_param
      ) do
    # Get collection configuration to find references
    case Collections.get_collection(group_name, collection_name) do
      {:ok, collection_config} ->
        base_query
        |> apply_expand_joins(collection_config, expand_param, group_name)
        |> apply_select_filtering(select_param)
        |> apply_filter_conditions(filter_param)
        |> apply_ordering(orderby_param)
        |> apply_pagination(skip_param, top_param)

      {:error, :not_found} ->
        # Fallback: apply operations without collection metadata
        base_query
        |> apply_select_filtering(select_param)
        |> apply_filter_conditions(filter_param)
        |> apply_ordering(orderby_param)
        |> apply_pagination(skip_param, top_param)
    end
  end

  # Apply $expand by adding LEFT JOIN clauses for navigation properties
  defp apply_expand_joins(base_query, _collection_config, nil, _group_name), do: base_query

  defp apply_expand_joins(base_query, collection_config, expand_param, group_name) do
    expanded_nav_props = String.split(expand_param, ",") |> Enum.map(&String.trim/1)
    build_joins_for_expand(base_query, collection_config, expanded_nav_props, group_name)
  end

  # Apply $select by wrapping query with column filtering
  defp apply_select_filtering(base_query, nil), do: base_query

  defp apply_select_filtering(base_query, select_param) do
    apply_select_to_query(base_query, select_param)
  end

  # Apply $filter using existing filter module
  defp apply_filter_conditions(base_query, filter_param) do
    Modeta.ODataFilter.apply_filter_to_query(base_query, filter_param)
  end

  # Apply $orderby by adding ORDER BY clause
  defp apply_ordering(base_query, nil), do: base_query

  defp apply_ordering(base_query, orderby_param) do
    apply_orderby_to_query(base_query, orderby_param)
  end

  # Apply pagination with LIMIT and OFFSET
  defp apply_pagination(base_query, skip_param, top_param) do
    apply_pagination_to_query(base_query, skip_param, top_param)
  end

  @doc """
  Applies $select to query by wrapping with SELECT clause containing only requested columns.
  """
  def apply_select_to_query(base_query, select_param) do
    # Parse $select parameter - comma-separated list of column names
    selected_columns =
      select_param
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if length(selected_columns) > 0 do
      column_list = Enum.join(selected_columns, ", ")
      "SELECT #{column_list} FROM (#{base_query}) AS selected_data"
    else
      # If no valid columns specified, return original query
      base_query
    end
  end

  @doc """
  Applies $orderby to query by adding ORDER BY clause.
  """
  def apply_orderby_to_query(base_query, orderby_param) do
    # Parse $orderby parameter - comma-separated list of "column [asc|desc]"
    order_clauses =
      orderby_param
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_order_clause/1)
      |> Enum.reject(&is_nil/1)

    if length(order_clauses) > 0 do
      order_by_clause = Enum.join(order_clauses, ", ")
      "SELECT * FROM (#{base_query}) AS ordered_data ORDER BY #{order_by_clause}"
    else
      # If no valid order clauses, return original query
      base_query
    end
  end

  @doc """
  Applies pagination to query with LIMIT and OFFSET.
  """
  def apply_pagination_to_query(base_query, skip_param, top_param) do
    # Get configuration values
    default_page_size = Application.get_env(:modeta, :default_page_size, 1000)
    max_page_size = Application.get_env(:modeta, :max_page_size, 5000)

    # Parse skip parameter (defaults to 0)
    skip =
      case skip_param do
        nil ->
          0

        skip_str when is_binary(skip_str) ->
          case Integer.parse(skip_str) do
            {num, ""} when num >= 0 -> num
            _ -> 0
          end

        skip_num when is_integer(skip_num) and skip_num >= 0 ->
          skip_num

        _ ->
          0
      end

    # Parse top parameter (defaults to default_page_size)
    top =
      case top_param do
        nil ->
          default_page_size

        top_str when is_binary(top_str) ->
          case Integer.parse(top_str) do
            {num, ""} when num > 0 -> min(num, max_page_size)
            _ -> default_page_size
          end

        top_num when is_integer(top_num) and top_num > 0 ->
          min(top_num, max_page_size)

        _ ->
          default_page_size
      end

    # Apply LIMIT and OFFSET to query
    # Use LIMIT + 1 to detect if more data exists for pagination
    "SELECT * FROM (#{base_query}) AS paginated_data LIMIT #{top + 1} OFFSET #{skip}"
  end

  # Build LEFT JOIN clauses for expanded navigation properties
  # Enhanced to support both manual configuration and automatic discovery
  defp build_joins_for_expand(base_query, collection_config, expanded_nav_props, group_name) do
    Enum.reduce(expanded_nav_props, base_query, fn nav_prop, query ->
      case find_navigation_reference(collection_config, group_name, nav_prop) do
        {:ok, reference} ->
          add_join_for_navigation_property(
            query,
            reference,
            nav_prop,
            group_name,
            collection_config.table_name
          )

        {:error, :no_reference} ->
          require Logger
          Logger.warning("No reference found for navigation property: #{nav_prop}")
          # Skip unknown navigation properties
          query
      end
    end)
  end

  @doc """
  Finds navigation reference using both manual configuration and automatic discovery.

  This function provides a unified interface for finding navigation references
  whether they are defined manually in collections.yml or discovered automatically
  from DuckDB foreign key constraints.

  ## Parameters
  - collection_config: Manual collection configuration
  - group_name: Schema/group name for automatic discovery
  - nav_prop: Navigation property name to find

  ## Returns
  - {:ok, reference} when reference is found (compatible with existing format)
  - {:error, :no_reference} when navigation property is not found
  """
  def find_navigation_reference(collection_config, group_name, nav_prop) do
    # First try manual configuration (existing behavior)
    case find_reference_for_navigation(collection_config.references, nav_prop) do
      {:ok, ref} ->
        {:ok, ref}

      {:error, :no_reference} ->
        # Try automatic discovery from DuckDB
        # Extract unqualified table name (remove schema prefix)
        unqualified_table_name =
          collection_config.table_name
          |> String.split(".")
          |> List.last()

        find_automatic_navigation_reference(group_name, unqualified_table_name, nav_prop)
    end
  end

  # Find navigation reference using automatic DuckDB foreign key discovery
  defp find_automatic_navigation_reference(schema_name, table_name, nav_prop) do
    case RelationshipDiscovery.get_navigation_properties(schema_name, table_name) do
      {:ok, nav_props} ->
        # Look in both belongs_to and has_many relationships
        all_nav_props = nav_props.belongs_to ++ nav_props.has_many

        matching_prop =
          Enum.find(all_nav_props, fn prop ->
            String.downcase(prop.name) == String.downcase(nav_prop)
          end)

        case matching_prop do
          nil ->
            {:error, :no_reference}

          prop ->
            # Convert discovered relationship to format compatible with existing code
            reference = convert_discovered_to_reference_format(prop)
            {:ok, reference}
        end

      _error ->
        {:error, :discovery_failed}
    end
  end

  # Convert discovered navigation property to reference format expected by existing code
  defp convert_discovered_to_reference_format(nav_prop) do
    case nav_prop.type do
      :belongs_to ->
        # For belongs_to: source table has foreign key pointing to target table
        %{
          "col" => nav_prop.source_column,
          "ref" => "#{nav_prop.target_table}(#{nav_prop.target_column})"
        }

      :has_many ->
        # For has_many: current table's primary key joins to target table's foreign key
        # customers.id → purchases.customer_id becomes: purchases(customer_id) references customers.id
        %{
          # The column on the current table (usually primary key)
          "col" => nav_prop.source_column,
          # Target table with its foreign key column that references this table
          "ref" => "#{nav_prop.target_table}(#{nav_prop.target_column})",
          # Mark this as reverse join for proper JOIN logic
          "_reverse_join" => true
        }
    end
  end

  @doc """
  Determines the appropriate JOIN type based on OData v4.01 query semantics.

  Follows OData specification for different operation types:
  - $expand operations: Always LEFT JOIN (inclusive - show all entities)
  - Navigation by key: Always INNER JOIN (entity must exist or 404)

  ## Parameters
  - operation_type: :expand | :navigation_by_key

  ## Returns
  - :inner_join or :left_join atom
  """
  def determine_join_type(operation_type) do
    case operation_type do
      # $expand: Always LEFT JOIN - OData standard inclusive semantics
      :expand -> :left_join
      # Navigation by key: Always INNER JOIN - entity must exist
      :navigation_by_key -> :inner_join
      # Default to LEFT JOIN for OData compliance
      _ -> :left_join
    end
  end

  # Find the reference configuration for a navigation property
  # Enhanced to support both manual configuration and automatic discovery
  defp find_reference_for_navigation(references, nav_prop) do
    # First try manual configuration (existing behavior)
    manual_ref = find_manual_reference(references, nav_prop)

    case manual_ref do
      {:ok, ref} ->
        {:ok, ref}

      {:error, :no_reference} ->
        # Fallback to automatic discovery (not implemented in this function)
        # This allows for future enhancement without breaking existing behavior
        {:error, :no_reference}
    end
  end

  # Find reference using manual configuration (original behavior)
  defp find_manual_reference(references, nav_prop) do
    target_ref =
      Enum.find(references, fn %{"ref" => ref_spec} ->
        case parse_reference_spec(ref_spec) do
          {:ok, {ref_table, _}} ->
            # Strip schema prefix and compare with navigation property (case insensitive)
            table_name = ref_table |> String.split(".") |> List.last()
            String.downcase(String.capitalize(table_name)) == String.downcase(nav_prop)

          _ ->
            false
        end
      end)

    case target_ref do
      nil -> {:error, :no_reference}
      ref -> {:ok, ref}
    end
  end

  # Add JOIN for a specific navigation property (INNER or LEFT based on relationship)
  defp add_join_for_navigation_property(
         base_query,
         reference,
         nav_prop,
         group_name,
         _source_table
       ) do
    %{"col" => source_column, "ref" => ref_spec} = reference
    is_reverse_join = Map.get(reference, "_reverse_join", false)

    case parse_reference_spec(ref_spec) do
      {:ok, {ref_table, ref_column}} ->
        # Ensure reference table has schema prefix
        qualified_ref_table =
          if String.contains?(ref_table, ".") do
            ref_table
          else
            "#{group_name}.#{ref_table}"
          end

        # Build alias for the joined table
        join_alias = String.downcase(nav_prop)

        # OData v4.01 specification: $expand always uses LEFT JOIN
        # This ensures all primary entities are returned even if navigation property is null
        join_sql = "LEFT JOIN"

        # Determine JOIN condition based on relationship direction
        {left_join_expr, right_join_expr} =
          if is_reverse_join do
            # For has_many: main.id = target.foreign_key (e.g., customers.id = purchases.customer_id)
            {"main.#{source_column}", "#{join_alias}.#{ref_column}"}
          else
            # For belongs_to: main.foreign_key = target.id (e.g., purchases.customer_id = customers.id)
            {"main.#{source_column}", "#{join_alias}.#{ref_column}"}
          end

        # Get target table columns for proper aliasing
        case get_table_columns_for_expand(qualified_ref_table, join_alias) do
          {:ok, aliased_columns} ->
            # Transform base query to include JOIN with proper column aliasing
            """
            SELECT main.*, #{aliased_columns}
            FROM (#{base_query}) AS main
            #{join_sql} #{qualified_ref_table} AS #{join_alias}
            ON #{left_join_expr} = #{right_join_expr}
            """

          {:error, _} ->
            # Fallback to simple join without column aliasing
            """
            SELECT main.*, #{join_alias}.*
            FROM (#{base_query}) AS main
            #{join_sql} #{qualified_ref_table} AS #{join_alias}
            ON #{left_join_expr} = #{right_join_expr}
            """
        end

      {:error, _} ->
        # Skip invalid reference specifications
        base_query
    end
  end

  # Get table columns for $expand with proper aliasing
  defp get_table_columns_for_expand(qualified_table, alias) do
    query = "DESCRIBE #{qualified_table}"

    case Cache.query(query) do
      {:ok, result} ->
        rows = Cache.to_rows(result)
        # Generate aliased column list: alias.col_name as alias_col_name
        aliased_columns =
          Enum.map_join(rows, ", ", fn row ->
            case row do
              [col_name, _type | _] when is_binary(col_name) ->
                "#{alias}.#{col_name} as #{alias}_#{col_name}"

              _ ->
                "#{alias}.*"
            end
          end)

        {:ok, aliased_columns}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parse reference specification like "customers(id)" or "sales_test.customers(id)"
  defp parse_reference_spec(ref_spec) do
    case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_.]*)\(([a-zA-Z_][a-zA-Z0-9_]*)\)$/, ref_spec) do
      [_, table, column] -> {:ok, {table, column}}
      nil -> {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end
  end

  # Parse individual order clause like "name asc" or "age desc" or just "id"
  defp parse_order_clause(clause) do
    parts = String.split(clause, " ", trim: true)

    case parts do
      [column] ->
        # Default to ascending if no direction specified
        sanitized_column = sanitize_column_name(column)

        if sanitized_column do
          "#{sanitized_column} ASC"
        else
          nil
        end

      [column, direction] ->
        # Check if direction is valid (case insensitive)
        normalized_direction = String.downcase(direction)
        sanitized_column = sanitize_column_name(column)

        if normalized_direction in ["asc", "desc"] and sanitized_column do
          "#{sanitized_column} #{String.upcase(normalized_direction)}"
        else
          # Invalid direction or column, skip this clause
          nil
        end

      _ ->
        # Invalid format, skip this clause
        nil
    end
  end

  # Sanitize column name to prevent SQL injection and validate column exists
  defp sanitize_column_name(column) do
    # Only allow alphanumeric characters, underscores, and dots (for qualified names)
    if Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)?$/, column) do
      column
    else
      # If invalid column name format, return nil to skip this clause
      nil
    end
  end
end
