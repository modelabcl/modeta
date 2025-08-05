defmodule Modeta.OData.ResponseFormatter do
  @moduledoc """
  Formats OData v4 JSON responses according to the OData specification.

  This module handles the construction of OData-compliant JSON responses including:
  - Row data formatting with proper object structure
  - Pagination responses with @odata.nextLink
  - Context URL generation for metadata
  - Content-type negotiation and headers
  - Navigation property expansion formatting

  Extracted from ModetaWeb.ODataController to separate response formatting 
  concerns from web layer logic.
  """

  alias Modeta.Collections

  @doc """
  Formats database rows as OData entity objects.

  Converts list of row data (lists) into proper JSON objects using column names.

  ## Parameters
  - rows: List of lists containing row data
  - column_names: List of column names matching row data

  ## Returns
  - List of maps representing OData entities
  """
  def format_rows_as_objects(rows, column_names) do
    Enum.map(rows, fn row ->
      column_names
      |> Enum.zip(row)
      |> Enum.map(fn {key, value} -> {key, serialize_duckdb_value(value)} end)
      |> Enum.into(%{})
    end)
  end

  @doc """
  Formats a single database row as an OData entity object.

  ## Parameters  
  - row: List containing single row data
  - column_names: List of column names matching row data

  ## Returns
  - Map representing single OData entity
  """
  def format_single_row_as_object(row, column_names) do
    column_names
    |> Enum.zip(row)
    |> Enum.map(fn {key, value} -> {key, serialize_duckdb_value(value)} end)
    |> Enum.into(%{})
  end

  @doc """
  Formats rows with expanded navigation properties.

  Processes query results that include JOINed navigation property data
  and formats them into proper OData expansion structure.

  ## Parameters
  - rows: List of lists containing joined row data
  - column_names: List of column names including expanded columns
  - group_name: Collection group name for configuration lookup
  - collection_name: Primary collection name
  - expand_param: $expand parameter value specifying which properties to expand

  ## Returns
  - List of maps with expanded navigation properties embedded
  """
  def format_rows_with_expansion(rows, column_names, group_name, collection_name, expand_param) do
    # Get collection configuration to understand which columns belong to expanded entities
    case Collections.get_collection(group_name, collection_name) do
      {:ok, collection_config} ->
        expanded_nav_props = String.split(expand_param, ",") |> Enum.map(&String.trim/1)

        Enum.map(rows, fn row ->
          base_entity = format_single_row_as_object(row, column_names)

          # Add expanded navigation properties
          Enum.reduce(expanded_nav_props, base_entity, fn nav_prop, entity ->
            case find_reference_for_navigation(collection_config.references, nav_prop) do
              {:ok, _reference} ->
                add_expanded_property_to_entity(entity, nav_prop, row, column_names)

              {:error, :no_reference} ->
                entity
            end
          end)
        end)

      {:error, :not_found} ->
        # Fallback to basic formatting
        format_rows_as_objects(rows, column_names)
    end
  end

  @doc """
  Builds paginated OData response with @odata.nextLink if needed.

  Creates the standard OData collection response format with proper pagination
  links when more results are available.

  ## Parameters
  - context_url: The @odata.context URL for metadata reference
  - rows: Formatted entity data
  - conn: Phoenix connection for URL building
  - group_name: Collection group name
  - collection_name: Collection name
  - params: Query parameters for next link construction
  - skip_param: Current $skip value
  - top_param: Current $top value

  ## Returns
  - Map containing @odata.context, value, and optionally @odata.nextLink
  """
  def build_paginated_response(
        context_url,
        rows,
        conn,
        group_name,
        collection_name,
        params,
        skip_param,
        top_param
      ) do
    # Get configuration values
    default_page_size = Application.get_env(:modeta, :default_page_size, 1000)
    max_page_size = Application.get_env(:modeta, :max_page_size, 5000)

    # Parse current pagination parameters
    current_skip =
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

    current_top =
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

    # Handle LIMIT + 1 pagination detection
    {actual_rows, has_more_results} =
      if length(rows) > current_top do
        # We got more rows than requested, so there are more results
        {Enum.take(rows, current_top), true}
      else
        # We got the exact number or fewer rows, so no more results
        {rows, false}
      end

    # Base response with actual rows (not including the extra detection row)
    base_response = %{
      "@odata.context" => context_url,
      "value" => actual_rows
    }

    # Only include @odata.nextLink if we actually detected more results
    if has_more_results do
      # Build next page URL
      next_skip = current_skip + current_top

      next_link =
        build_next_link_url(conn, group_name, collection_name, params, next_skip, current_top)

      Map.put(base_response, "@odata.nextLink", next_link)
    else
      # No more results, return base response without nextLink
      base_response
    end
  end

  @doc """
  Builds the URL for the next page in pagination.

  ## Parameters
  - conn: Phoenix connection for base URL construction
  - group_name: Collection group name
  - collection_name: Collection name
  - params: Current query parameters
  - next_skip: Skip value for next page
  - current_top: Current page size

  ## Returns
  - String containing the full next page URL
  """
  def build_next_link_url(conn, group_name, collection_name, params, next_skip, current_top) do
    # Build base URL
    base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}/#{group_name}/#{collection_name}"

    # Build query parameters, replacing $skip and preserving others
    query_params =
      params
      |> Map.put("$skip", Integer.to_string(next_skip))
      |> Map.put("$top", Integer.to_string(current_top))
      |> Enum.map_join("&", fn {key, value} -> "#{key}=#{URI.encode(value)}" end)

    "#{base_url}?#{query_params}"
  end

  @doc """
  Builds OData context URL with optional $select parameter support.

  Creates the @odata.context URL that references the metadata document
  and specifies the entity set being returned.

  ## Parameters
  - base_url: Base URL for the service
  - entity_set: Name of the entity set or collection
  - select_param: Optional $select parameter value

  ## Returns
  - String containing the context URL
  """
  def build_context_url(base_url, entity_set, select_param \\ nil)

  def build_context_url(base_url, entity_set, nil), do: "#{base_url}/$metadata##{entity_set}"

  def build_context_url(base_url, entity_set, select_param) do
    # Parse selected columns
    selected_columns =
      select_param
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if length(selected_columns) > 0 do
      select_clause = Enum.join(selected_columns, ",")
      "#{base_url}/$metadata##{entity_set}(#{select_clause})"
    else
      "#{base_url}/$metadata##{entity_set}"
    end
  end

  @doc """
  Determines appropriate OData content type based on Accept header.

  Handles content negotiation for OData metadata parameter (minimal, full, none)
  and returns properly formatted content-type header value.

  ## Parameters
  - accept_header: Accept header value from HTTP request

  ## Returns
  - String containing OData-compliant content-type header value
  """
  def get_odata_content_type(accept_header) when is_binary(accept_header) do
    metadata_type =
      cond do
        String.contains?(accept_header, "odata.metadata=full") -> "full"
        String.contains?(accept_header, "odata.metadata=none") -> "none"
        true -> "minimal"
      end

    # Build full OData content type like jaystack server
    "application/json;odata.metadata=#{metadata_type};odata.streaming=true;IEEE754Compatible=false"
  end

  def get_odata_content_type(_),
    do: "application/json;odata.metadata=minimal;odata.streaming=true;IEEE754Compatible=false"

  # Private helper functions

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

  # Parse reference specification like "customers(id)" or "sales_test.customers(id)"
  defp parse_reference_spec(ref_spec) do
    case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_.]*)\(([a-zA-Z_][a-zA-Z0-9_]*)\)$/, ref_spec) do
      [_, table, column] -> {:ok, {table, column}}
      nil -> {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end
  end

  # Add expanded navigation property data to entity
  defp add_expanded_property_to_entity(entity, nav_prop, row, column_names) do
    # Find columns that likely belong to the expanded entity
    join_alias = String.downcase(nav_prop)

    expanded_columns =
      Enum.filter(column_names, fn col_name ->
        String.starts_with?(String.downcase(col_name), join_alias <> "_")
      end)

    if length(expanded_columns) > 0 do
      # Extract expanded entity data
      expanded_data =
        expanded_columns
        |> Enum.map(fn col_name ->
          col_index = Enum.find_index(column_names, &(&1 == col_name))

          if col_index do
            # Remove alias prefix from column name
            clean_col_name = String.replace(col_name, ~r/^#{join_alias}_?/i, "")
            value = Enum.at(row, col_index)
            # Apply DuckDB value serialization to expanded data too
            serialized_value = serialize_duckdb_value(value)
            {clean_col_name, serialized_value}
          else
            nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.into(%{})

      # Only add if we have actual data
      if map_size(expanded_data) > 0 do
        Map.put(entity, nav_prop, expanded_data)
      else
        entity
      end
    else
      entity
    end
  end

  # Private helper functions

  # Serializes DuckDB values to JSON-compatible formats.
  # Handles DuckDB-specific types that aren't natively JSON serializable:
  # - Date tuples {year, month, day} -> "YYYY-MM-DD"
  # - Time tuples {hour, minute, second} -> "HH:MM:SS"
  # - DateTime tuples -> ISO8601 strings
  # - Other values pass through unchanged
  defp serialize_duckdb_value({year, month, day})
       when is_integer(year) and is_integer(month) and is_integer(day) do
    # Date tuple -> ISO date string
    "#{year}-#{String.pad_leading(to_string(month), 2, "0")}-#{String.pad_leading(to_string(day), 2, "0")}"
  end

  defp serialize_duckdb_value({hour, minute, second})
       when is_integer(hour) and is_integer(minute) and is_integer(second) do
    # Time tuple -> ISO time string
    "#{String.pad_leading(to_string(hour), 2, "0")}:#{String.pad_leading(to_string(minute), 2, "0")}:#{String.pad_leading(to_string(second), 2, "0")}"
  end

  defp serialize_duckdb_value({{year, month, day}, {hour, minute, second}}) do
    # DateTime tuple -> ISO datetime string
    date_part =
      "#{year}-#{String.pad_leading(to_string(month), 2, "0")}-#{String.pad_leading(to_string(day), 2, "0")}"

    time_part =
      "#{String.pad_leading(to_string(hour), 2, "0")}:#{String.pad_leading(to_string(minute), 2, "0")}:#{String.pad_leading(to_string(second), 2, "0")}"

    "#{date_part}T#{time_part}"
  end

  defp serialize_duckdb_value(value) do
    # Pass through other values unchanged
    value
  end
end
