defmodule ModetaWeb.ODataController do
  use ModetaWeb, :controller

  alias Modeta.{Cache, Collections}
  alias Modeta.OData.{QueryBuilder, ResponseFormatter, NavigationResolver, PaginationHandler}

  @doc """
  Returns OData service metadata (XML/CSDL format).
  Required by OData specification.
  """
  def metadata(conn, %{"collection_group" => group_name}) do
    # Get collections for the specific group
    collections = Collections.get_collections_for_group(group_name)
    collection_names = Enum.map(collections, & &1.name)

    # Get schema information for each collection in the group
    schemas = get_collection_schemas_for_group(group_name, collection_names)

    # Generate XML directly using our HTML module
    metadata_xml = ModetaWeb.ODataHTML.metadata(%{collection_schemas: schemas})

    conn
    |> put_resp_content_type("application/xml")
    |> put_resp_header("odata-version", "4.0")
    |> text(metadata_xml)
  end

  @doc """
  Returns OData service document.

  Lists available collections/entity sets.
  """
  def service_document(conn, %{"collection_group" => group_name}) do
    # Debug: Log Accept headers
    accept_header = get_req_header(conn, "accept") |> List.first()
    require Logger
    Logger.info("Service document request - Accept: #{inspect(accept_header)}")

    collections = Collections.get_collections_for_group(group_name)

    # Build absolute URLs like the working TripPin service
    base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}#{conn.request_path}"
    base_url = String.trim_trailing(base_url, "/")

    # Ensure @odata.context comes first like the working JS server
    service_doc = %{
      "@odata.context" => "#{base_url}/$metadata",
      "value" =>
        Enum.map(collections, fn collection ->
          %{
            "name" => collection.name,
            "kind" => "EntitySet",
            "url" => collection.name
          }
        end)
    }

    # Respond with OData-specific content type based on Accept header
    content_type = ResponseFormatter.get_odata_content_type(accept_header)

    conn
    |> put_resp_header("odata-version", "4.0")
    |> put_resp_content_type(content_type)
    |> json(service_doc)
  end

  @doc """
  Handles OData navigation property requests.
  Returns related entities via foreign key relationships.
  """
  def navigation_property(conn, %{
        "collection_group" => group_name,
        "collection_with_key" => collection_with_key,
        "navigation_property" => nav_prop
      }) do
    # Parse collection name and key from format "purchases(1)"
    case NavigationResolver.parse_collection_and_key(collection_with_key) do
      {:ok, collection_name, key} ->
        # Get the collection configuration to find references
        case Collections.get_collection(group_name, collection_name) do
          {:ok, collection_config} ->
            NavigationResolver.handle_navigation_request(
              conn,
              group_name,
              collection_config,
              key,
              nav_prop
            )

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{message: "Collection '#{collection_name}' not found"}})
        end

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{message: "Invalid collection key format: #{reason}"}})
    end
  end

  @doc """
  Handles OData collection requests.
  Returns JSON data for the specified collection.
  Supports $filter query parameter for server-side filtering.
  """
  def collection(
        conn,
        %{"collection_group" => group_name, "collection" => collection_param} = params
      ) do
    # Check if this is an entity-by-key request (e.g., "customers(1)")
    case NavigationResolver.parse_collection_and_key(collection_param) do
      {:ok, collection_name, key} ->
        # Handle entity by key request
        handle_entity_by_key_request(conn, group_name, collection_name, key, params)

      {:error, _} ->
        # Handle regular collection request
        handle_collection_request(conn, group_name, collection_param, params)
    end
  end

  # Handle regular collection requests (no key)
  defp handle_collection_request(conn, group_name, collection_name, params) do
    case Collections.get_query(group_name, collection_name) do
      {:ok, base_query} ->
        # Apply $filter, $expand, $select, $orderby, $count, and pagination if provided
        filter_param = Map.get(params, "$filter")
        expand_param = Map.get(params, "$expand")
        select_param = Map.get(params, "$select")
        orderby_param = Map.get(params, "$orderby")
        count_param = Map.get(params, "$count")
        skip_param = Map.get(params, "$skip")
        top_param = Map.get(params, "$top")

        # Build query with all OData options support using QueryBuilder
        final_query =
          QueryBuilder.build_query_with_options(
            base_query,
            group_name,
            collection_name,
            filter_param,
            expand_param,
            select_param,
            orderby_param,
            skip_param,
            top_param
          )

        case Cache.query(final_query) do
          {:ok, result} ->
            rows = Cache.to_rows(result)
            column_names = get_column_names(result)

            # Get total count if requested
            total_count =
              if PaginationHandler.should_include_count?(count_param) do
                PaginationHandler.get_total_count(base_query, filter_param)
              else
                nil
              end

            # Build absolute URL for context using the group name
            base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}/#{group_name}"

            # Process expanded data if $expand was requested
            formatted_rows =
              if expand_param do
                ResponseFormatter.format_rows_with_expansion(
                  rows,
                  column_names,
                  group_name,
                  collection_name,
                  expand_param
                )
              else
                ResponseFormatter.format_rows_as_objects(rows, column_names)
              end

            # Build context URL with $select parameters if applicable
            context_url =
              ResponseFormatter.build_context_url(base_url, collection_name, select_param)

            # Check if we need pagination and build @odata.nextLink
            response =
              ResponseFormatter.build_paginated_response(
                context_url,
                formatted_rows,
                conn,
                group_name,
                collection_name,
                params,
                skip_param,
                top_param
              )

            # Add @odata.count if requested
            final_response =
              if total_count do
                Map.put(response, "@odata.count", total_count)
              else
                response
              end

            # Get OData content type from Accept header
            accept_header = get_req_header(conn, "accept") |> List.first()
            content_type = ResponseFormatter.get_odata_content_type(accept_header)

            conn
            |> put_resp_header("odata-version", "4.0")
            |> put_resp_content_type(content_type)
            |> json(final_response)

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

  # Handle entity by key requests (e.g., /customers(1))
  defp handle_entity_by_key_request(conn, group_name, collection_name, key, params) do
    case Collections.get_query(group_name, collection_name) do
      {:ok, base_query} ->
        # Add WHERE clause to filter by primary key (assuming 'id' column)
        entity_query = "#{base_query} WHERE id = #{key}"

        # Apply $expand and $select if provided
        expand_param = Map.get(params, "$expand")
        select_param = Map.get(params, "$select")

        final_query =
          QueryBuilder.build_query_with_options(
            entity_query,
            group_name,
            collection_name,
            nil,
            expand_param,
            select_param,
            nil,
            nil,
            nil
          )

        case Cache.query(final_query) do
          {:ok, result} ->
            rows = Cache.to_rows(result)
            column_names = get_column_names(result)

            case rows do
              [single_row] ->
                # Build absolute URL for context
                base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}/#{group_name}"

                # Process expanded data if requested
                entity =
                  if expand_param do
                    ResponseFormatter.format_rows_with_expansion(
                      [single_row],
                      column_names,
                      group_name,
                      collection_name,
                      expand_param
                    )
                    |> List.first()
                  else
                    ResponseFormatter.format_single_row_as_object(single_row, column_names)
                  end

                # Build context URL with $select parameters if applicable
                context_url =
                  ResponseFormatter.build_context_url(
                    base_url,
                    "#{collection_name}/$entity",
                    select_param
                  )

                # OData single entity response format
                response =
                  %{
                    "@odata.context" => context_url
                  }
                  |> Map.merge(entity)

                # Get OData content type from Accept header
                accept_header = get_req_header(conn, "accept") |> List.first()
                content_type = ResponseFormatter.get_odata_content_type(accept_header)

                conn
                |> put_resp_header("odata-version", "4.0")
                |> put_resp_content_type(content_type)
                |> json(response)

              [] ->
                conn
                |> put_status(:not_found)
                |> json(%{error: %{message: "Entity with key '#{key}' not found"}})

              _multiple ->
                # This shouldn't happen with a proper primary key
                conn
                |> put_status(:internal_server_error)
                |> json(%{error: %{message: "Multiple entities found for key '#{key}'"}})
            end

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

  # Get schema information for collections in a specific group
  defp get_collection_schemas_for_group(group_name, collection_names) do
    collections = Collections.get_collections_for_group(group_name)

    Enum.map(collection_names, fn collection_name ->
      collection_config = Enum.find(collections, &(&1.name == collection_name))

      case get_table_schema_for_group(group_name, collection_name) do
        {:ok, schema} ->
          %{
            name: collection_name,
            schema: schema,
            references: (collection_config && collection_config.references) || []
          }

        {:error, _reason} ->
          # Fallback to basic schema if table doesn't exist yet
          %{
            name: collection_name,
            schema: [%{name: "Id", type: "VARCHAR"}, %{name: "Name", type: "VARCHAR"}],
            references: (collection_config && collection_config.references) || []
          }
      end
    end)
  end

  # Get DuckDB table schema for a collection in a specific group
  defp get_table_schema_for_group(group_name, collection_name) do
    with {:ok, query} <- Collections.get_query(group_name, collection_name),
         {:ok, _} <- create_temp_view_for_group(group_name, collection_name, query),
         {:ok, result} <- Cache.describe_table("temp_#{group_name}_#{collection_name}_schema") do
      schema = extract_schema_from_describe(result)
      # Clean up temp view
      Cache.query("DROP VIEW IF EXISTS temp_#{group_name}_#{collection_name}_schema")
      {:ok, schema}
    end
  end

  defp create_temp_view_for_group(group_name, collection_name, query) do
    temp_query = "CREATE OR REPLACE VIEW temp_#{group_name}_#{collection_name}_schema AS #{query}"
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
