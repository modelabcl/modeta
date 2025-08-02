defmodule Modeta.OData.QueryBuilder do
  @moduledoc """
  Builds SQL queries from OData system query options.

  This module handles the construction of SQL queries based on OData v4 system
  query options like $filter, $select, $expand, $orderby, and pagination.

  Extracted from ModetaWeb.ODataController to separate domain logic from web logic.
  """

  alias Modeta.{Collections, Cache}

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
    "SELECT * FROM (#{base_query}) AS paginated_data LIMIT #{top} OFFSET #{skip}"
  end

  # Build LEFT JOIN clauses for expanded navigation properties
  defp build_joins_for_expand(base_query, collection_config, expanded_nav_props, group_name) do
    Enum.reduce(expanded_nav_props, base_query, fn nav_prop, query ->
      case find_reference_for_navigation(collection_config.references, nav_prop) do
        {:ok, reference} ->
          add_join_for_navigation_property(
            query,
            reference,
            nav_prop,
            group_name,
            collection_config.table_name
          )

        {:error, :no_reference} ->
          # Skip unknown navigation properties
          query
      end
    end)
  end

  @doc """
  Determines the appropriate JOIN type based on OData v4.01 semantics.
  
  Follows OData CSDL specification for navigation property relationships:
  - INNER JOIN: Required relationships (nullable: false, multiplicity: "1")
  - LEFT JOIN: Optional relationships (nullable: true, multiplicity: "0..1") 
  
  ## Parameters
  - reference: Reference configuration map with nullable, multiplicity, join_type
  
  ## Returns
  - :inner_join or :left_join atom
  """
  def determine_join_type(reference) do
    case reference do
      # Explicit join_type specification takes precedence
      %{"join_type" => "inner"} -> :inner_join
      %{"join_type" => "left"} -> :left_join
      
      # OData v4.01 CSDL semantics: non-nullable → INNER JOIN
      %{"nullable" => false} -> :inner_join
      
      # Required relationship (multiplicity "1") → INNER JOIN  
      %{"multiplicity" => "1"} -> :inner_join
      
      # Default to LEFT JOIN for inclusive OData semantics
      _ -> :left_join
    end
  end

  # Find the reference configuration for a navigation property
  defp find_reference_for_navigation(references, nav_prop) do
    # Navigation property name should match the referenced table name
    # For reference like "col: customer_id, ref: customers(id)", nav_prop would be "Customers"
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
    %{"col" => foreign_key_column, "ref" => ref_spec} = reference

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
        
        # Determine JOIN type based on OData v4.01 semantics
        join_type = determine_join_type(reference)
        join_sql = case join_type do
          :inner_join -> "INNER JOIN"
          :left_join -> "LEFT JOIN"
        end

        # Get target table columns for proper aliasing
        case get_table_columns_for_expand(qualified_ref_table, join_alias) do
          {:ok, aliased_columns} ->
            # Transform base query to include JOIN with proper column aliasing
            """
            SELECT main.*, #{aliased_columns}
            FROM (#{base_query}) AS main
            #{join_sql} #{qualified_ref_table} AS #{join_alias}
            ON main.#{foreign_key_column} = #{join_alias}.#{ref_column}
            """

          {:error, _} ->
            # Fallback to simple join without column aliasing
            """
            SELECT main.*, #{join_alias}.*
            FROM (#{base_query}) AS main
            #{join_sql} #{qualified_ref_table} AS #{join_alias}
            ON main.#{foreign_key_column} = #{join_alias}.#{ref_column}
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
