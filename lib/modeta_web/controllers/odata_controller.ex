defmodule ModetaWeb.ODataController do
  use ModetaWeb, :controller

  alias Modeta.{Cache, Collections}

  @doc """
  Returns OData service metadata (XML/CSDL format).
  Required by OData specification.
  """
  def metadata(conn, _params) do
    # Get available collections
    collections = Collections.list_available()

    # Get schema information for each collection
    schemas = get_collection_schemas(collections)

    # Generate XML directly using our HTML module
    metadata_xml = ModetaWeb.ODataHTML.metadata(%{collection_schemas: schemas})

    conn
    |> put_resp_content_type("application/xml")
    |> put_resp_header("OData-Version", "4.0")
    |> text(metadata_xml)
  end

  @doc """
  Returns OData service document.

  Lists available collections/entity sets.
  """
  def service_document(conn, _params) do
    # Debug: Log Accept headers
    accept_header = get_req_header(conn, "accept") |> List.first()
    require Logger
    Logger.info("Service document request - Accept: #{inspect(accept_header)}")

    collections = Collections.list_available()

    # Build absolute URLs like the working TripPin service
    base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}#{conn.request_path}"
    base_url = String.trim_trailing(base_url, "/")

    # Ensure @odata.context comes first like the working JS server
    service_doc = %{
      "@odata.context" => "#{base_url}/$metadata",
      "value" =>
        Enum.map(collections, fn collection ->
          %{
            "name" => collection,
            "kind" => "EntitySet",
            "url" => collection
          }
        end)
    }

    # Respond with OData-specific content type based on Accept header
    content_type = get_odata_content_type(accept_header)

    conn
    |> put_resp_header("OData-Version", "4.0")
    |> put_resp_content_type(content_type)
    |> json(service_doc)
  end

  @doc """
  Handles OData collection requests.
  Returns JSON data for the specified collection.
  Supports $filter query parameter for server-side filtering.
  """
  def collection(conn, %{"collection" => collection_name} = params) do
    case Collections.get_query(collection_name) do
      {:ok, base_query} ->
        # Apply $filter if provided
        filter_param = Map.get(params, "$filter")
        final_query = Modeta.ODataFilter.apply_filter_to_query(base_query, filter_param)

        case Cache.query(final_query) do
          {:ok, result} ->
            rows = Cache.to_rows(result)
            column_names = get_column_names(result)

            # Build absolute URL for context
            base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}/modeta"

            # Match JS server format - @odata.context first, then value
            response = %{
              "@odata.context" => "#{base_url}/$metadata##{collection_name}",
              "value" => format_rows_as_objects(rows, column_names)
            }

            # Get OData content type from Accept header
            accept_header = get_req_header(conn, "accept") |> List.first()
            content_type = get_odata_content_type(accept_header)

            conn
            |> put_resp_header("OData-Version", "4.0")
            |> put_resp_content_type(content_type)
            |> json(response)

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: %{message: "Database query failed: #{inspect(reason)}"}})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Collection '#{collection_name}' not found"}})
    end
  end

  # Extract column names from ADBC result
  defp get_column_names(%Adbc.Result{data: columns}) do
    Enum.map(columns, & &1.name)
  end

  # Convert rows (list of lists) to list of objects using column names
  defp format_rows_as_objects(rows, column_names) do
    Enum.map(rows, fn row ->
      column_names
      |> Enum.zip(row)
      |> Enum.into(%{})
    end)
  end

  # Get appropriate OData content type based on Accept header
  defp get_odata_content_type(accept_header) when is_binary(accept_header) do
    metadata_type =
      cond do
        String.contains?(accept_header, "odata.metadata=full") -> "full"
        String.contains?(accept_header, "odata.metadata=none") -> "none"
        true -> "minimal"
      end

    # Build full OData content type like jaystack server
    "application/json;odata.metadata=#{metadata_type};odata.streaming=true;IEEE754Compatible=false"
  end

  defp get_odata_content_type(_),
    do: "application/json;odata.metadata=minimal;odata.streaming=true;IEEE754Compatible=false"

  # Get schema information for collections by introspecting DuckDB tables
  defp get_collection_schemas(collections) do
    Enum.map(collections, fn collection_name ->
      case get_table_schema(collection_name) do
        {:ok, schema} ->
          %{name: collection_name, schema: schema}

        {:error, _reason} ->
          # Fallback to basic schema if table doesn't exist yet
          %{
            name: collection_name,
            schema: [%{name: "Id", type: "VARCHAR"}, %{name: "Name", type: "VARCHAR"}]
          }
      end
    end)
  end

  # Get DuckDB table schema for a collection
  defp get_table_schema(collection_name) do
    with {:ok, query} <- Collections.get_query(collection_name),
         {:ok, _} <- create_temp_view(collection_name, query),
         {:ok, result} <- Cache.describe_table("temp_#{collection_name}_schema") do
      schema = extract_schema_from_describe(result)
      # Clean up temp view
      Cache.query("DROP VIEW IF EXISTS temp_#{collection_name}_schema")
      {:ok, schema}
    end
  end

  defp create_temp_view(collection_name, query) do
    temp_query = "CREATE OR REPLACE VIEW temp_#{collection_name}_schema AS #{query}"
    Cache.query(temp_query)
  end

  # Extract schema information from DESCRIBE result
  defp extract_schema_from_describe(%Adbc.Result{data: columns}) do
    rows = Cache.to_rows(%Adbc.Result{data: columns})
    column_names = Enum.map(columns, & &1.name)

    # DESCRIBE typically returns: column_name, column_type, null, key, default, extra
    name_index = Enum.find_index(column_names, &(&1 == "column_name"))
    type_index = Enum.find_index(column_names, &(&1 == "column_type"))

    if name_index && type_index do
      Enum.map(rows, fn row ->
        %{
          name: Enum.at(row, name_index),
          type: Enum.at(row, type_index)
        }
      end)
    else
      # Fallback if DESCRIBE format is different
      []
    end
  end
end
