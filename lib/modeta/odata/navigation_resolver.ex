defmodule Modeta.OData.NavigationResolver do
  @moduledoc """
  Resolves OData navigation properties and handles entity-by-key operations.

  This module handles the resolution of navigation property requests and parsing
  of entity key expressions in OData URLs. It provides functionality for:
  - Parsing collection and key from URLs like "customers(1)"
  - Finding reference configurations for navigation properties
  - Parsing reference specifications like "customers(id)" 
  - Building SQL queries for navigation property resolution
  - Executing navigation queries and formatting responses

  Extracted from ModetaWeb.ODataController to separate navigation logic
  from web layer concerns.
  """

  alias Modeta.Cache
  alias Modeta.OData.ResponseFormatter

  @doc """
  Parses collection name and key from OData entity-by-key format.

  Extracts collection name and key value from URLs like:
  - "customers(1)" -> {:ok, "customers", "1"}
  - "orders(abc-123)" -> {:ok, "orders", "abc-123"}

  ## Parameters
  - collection_with_key: String in format "collection(key)"

  ## Returns
  - {:ok, collection_name, key} on success
  - {:error, reason} on invalid format
  """
  def parse_collection_and_key(collection_with_key) do
    case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_]*)\(([^)]+)\)$/, collection_with_key) do
      [_, collection_name, key] -> {:ok, collection_name, key}
      nil -> {:error, "Expected format: collection(key)"}
    end
  end

  @doc """
  Finds the reference configuration for a navigation property.

  Searches through collection references to find the one matching
  the requested navigation property name.

  ## Parameters
  - references: List of reference configurations from collection config
  - nav_prop: Navigation property name (e.g., "Customers")

  ## Returns
  - {:ok, reference} when matching reference is found
  - {:error, :no_reference} when no matching reference exists
  """
  def find_reference_for_navigation(references, nav_prop) do
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

  @doc """
  Parses reference specification into table and column components.

  Handles reference specifications like:
  - "customers(id)" -> {:ok, {"customers", "id"}}
  - "sales_test.customers(id)" -> {:ok, {"sales_test.customers", "id"}}

  ## Parameters
  - ref_spec: Reference specification string

  ## Returns
  - {:ok, {table, column}} on successful parsing
  - {:error, reason} on invalid format
  """
  def parse_reference_spec(ref_spec) do
    case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_.]*)\(([a-zA-Z_][a-zA-Z0-9_]*)\)$/, ref_spec) do
      [_, table, column] -> {:ok, {table, column}}
      nil -> {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end
  end

  @doc """
  Handles navigation property request by finding and querying related entities.

  Orchestrates the complete navigation property resolution process:
  1. Find matching reference configuration
  2. Execute navigation query
  3. Format and return response

  ## Parameters
  - conn: Phoenix connection for response building
  - group_name: Collection group name
  - collection_config: Configuration for the source collection
  - key: Entity key value
  - nav_prop: Navigation property name

  ## Returns
  - Phoenix connection with JSON response
  """
  def handle_navigation_request(conn, group_name, collection_config, key, nav_prop) do
    # Find the reference that matches the navigation property
    case find_reference_for_navigation(collection_config.references, nav_prop) do
      {:ok, reference} ->
        execute_navigation_query(conn, group_name, collection_config, key, reference, nav_prop)

      {:error, :no_reference} ->
        conn
        |> Plug.Conn.put_status(:not_found)
        |> Phoenix.Controller.json(%{
          error: %{message: "Navigation property '#{nav_prop}' not found"}
        })
    end
  end

  @doc """
  Executes SQL query to retrieve related entities via navigation property.

  Builds and executes a JOIN query to find entities related through
  foreign key relationships, then formats the response appropriately.

  ## Parameters
  - conn: Phoenix connection for response building
  - group_name: Collection group name  
  - collection_config: Configuration for the source collection
  - key: Entity key value
  - reference: Reference configuration map
  - nav_prop: Navigation property name

  ## Returns
  - Phoenix connection with JSON response containing related entities
  """
  def execute_navigation_query(conn, group_name, collection_config, key, reference, nav_prop) do
    %{"col" => foreign_key_column, "ref" => ref_spec} = reference

    case parse_reference_spec(ref_spec) do
      {:ok, {ref_table, ref_column}} ->
        # Build the JOIN query to get related entities
        qualified_ref_table =
          if String.contains?(ref_table, ".") do
            ref_table
          else
            "#{group_name}.#{ref_table}"
          end

        # Query: SELECT target.* FROM target_table target
        #        JOIN source_table source ON target.ref_column = source.foreign_key_column
        #        WHERE source.primary_key = key
        query = """
        SELECT target.*
        FROM #{qualified_ref_table} target
        JOIN #{collection_config.table_name} source ON target.#{ref_column} = source.#{foreign_key_column}
        WHERE source.id = #{key}
        """

        case Cache.query(query) do
          {:ok, result} ->
            rows = Cache.to_rows(result)
            column_names = extract_column_names(result)

            # Build response - navigation properties return single entity or collection
            build_navigation_response(conn, group_name, nav_prop, rows, column_names)

          {:error, reason} ->
            conn
            |> Plug.Conn.put_status(:internal_server_error)
            |> Phoenix.Controller.json(%{
              error: %{message: "Navigation query failed: #{inspect(reason)}"}
            })
        end

      {:error, reason} ->
        conn
        |> Plug.Conn.put_status(:internal_server_error)
        |> Phoenix.Controller.json(%{
          error: %{message: "Invalid reference specification: #{reason}"}
        })
    end
  end

  # Private helper functions

  # Extract column names from ADBC result
  defp extract_column_names(%Adbc.Result{data: columns}) do
    Enum.map(columns, & &1.name)
  end

  # Build navigation property response based on result count
  defp build_navigation_response(conn, group_name, nav_prop, rows, column_names) do
    case rows do
      [single_row] ->
        # Single related entity
        build_single_entity_response(conn, group_name, nav_prop, single_row, column_names)

      [] ->
        # No related entities found
        conn
        |> Plug.Conn.put_status(:not_found)
        |> Phoenix.Controller.json(%{error: %{message: "Related entity not found"}})

      multiple_rows ->
        # Multiple related entities - return as collection
        build_collection_response(conn, group_name, nav_prop, multiple_rows, column_names)
    end
  end

  # Build response for single related entity
  defp build_single_entity_response(conn, group_name, nav_prop, row, column_names) do
    entity = ResponseFormatter.format_single_row_as_object(row, column_names)
    base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}/#{group_name}"

    response =
      %{
        "@odata.context" => "#{base_url}/$metadata##{String.downcase(nav_prop)}/$entity"
      }
      |> Map.merge(entity)

    accept_header = Plug.Conn.get_req_header(conn, "accept") |> List.first()
    content_type = ResponseFormatter.get_odata_content_type(accept_header)

    conn
    |> Plug.Conn.put_resp_header("odata-version", "4.0")
    |> Plug.Conn.put_resp_content_type(content_type)
    |> Phoenix.Controller.json(response)
  end

  # Build response for multiple related entities
  defp build_collection_response(conn, group_name, nav_prop, rows, column_names) do
    entities = ResponseFormatter.format_rows_as_objects(rows, column_names)
    base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}/#{group_name}"

    response = %{
      "@odata.context" => "#{base_url}/$metadata##{String.downcase(nav_prop)}",
      "value" => entities
    }

    accept_header = Plug.Conn.get_req_header(conn, "accept") |> List.first()
    content_type = ResponseFormatter.get_odata_content_type(accept_header)

    conn
    |> Plug.Conn.put_resp_header("odata-version", "4.0")
    |> Plug.Conn.put_resp_content_type(content_type)
    |> Phoenix.Controller.json(response)
  end
end
