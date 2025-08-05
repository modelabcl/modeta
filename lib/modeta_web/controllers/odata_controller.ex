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
            # If there's an expand parameter, we need to get the expected column names
            # including the expanded columns based on the SQL query that was built
            column_names =
              if expand_param do
                # Build expected column names including expanded columns
                build_expanded_column_names(
                  group_name,
                  collection_name,
                  expand_param,
                  select_param
                )
              else
                get_effective_column_names(group_name, collection_name, select_param)
              end

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
            # Use same expanded column names logic as collection handler
            column_names =
              if expand_param do
                # Build expected column names including expanded columns
                build_expanded_column_names(
                  group_name,
                  collection_name,
                  expand_param,
                  select_param
                )
              else
                get_effective_column_names(group_name, collection_name, select_param)
              end

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

  # Get column names for a collection using schema cache
  defp get_column_names_for_collection(group_name, collection_name) do
    Modeta.SchemaCache.get_column_names(group_name, collection_name)
  end

  # Get column names in the order they appear in the query result
  # If $select is used, return columns in the select order
  # Otherwise, return all columns in schema order
  defp get_effective_column_names(group_name, collection_name, select_param) do
    if select_param && String.trim(select_param) != "" do
      # Parse select parameter and return columns in that order
      select_param
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      # No select param, return all columns in schema order
      get_column_names_for_collection(group_name, collection_name)
    end
  end

  # Build column names list for queries with expanded navigation properties
  defp build_expanded_column_names(group_name, collection_name, expand_param, select_param) do
    # Start with base table columns
    base_columns =
      if select_param && String.trim(select_param) != "" do
        # Parse select parameter and return columns in that order
        select_param
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
      else
        # Get all base table columns
        get_column_names_for_collection(group_name, collection_name)
      end

    # Add expanded columns for each navigation property
    expanded_nav_props = String.split(expand_param, ",") |> Enum.map(&String.trim/1)

    expanded_columns =
      Enum.flat_map(expanded_nav_props, fn nav_prop ->
        # Get the target table for this navigation property
        case Collections.get_collection(group_name, collection_name) do
          {:ok, collection_config} ->
            case find_reference_for_navigation_table(collection_config.references, nav_prop) do
              {:ok, target_table} ->
                # Get columns for the target table and add alias prefix
                join_alias = String.downcase(nav_prop)

                case get_column_names_for_collection(group_name, target_table) do
                  columns when is_list(columns) ->
                    Enum.map(columns, fn col -> "#{join_alias}_#{col}" end)

                  _ ->
                    []
                end

              {:error, _} ->
                []
            end

          {:error, _} ->
            []
        end
      end)

    # Combine base and expanded columns
    base_columns ++ expanded_columns
  end

  # Find the target table name for a navigation property
  defp find_reference_for_navigation_table(references, nav_prop) do
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
      nil ->
        {:error, :no_reference}

      %{"ref" => ref_spec} ->
        case parse_reference_spec(ref_spec) do
          {:ok, {ref_table, _}} ->
            table_name = ref_table |> String.split(".") |> List.last()
            {:ok, table_name}

          error ->
            error
        end
    end
  end

  # Parse reference specification like "customers(id)" or "sales_test.customers(id)"
  defp parse_reference_spec(ref_spec) do
    case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_.]*)\(([a-zA-Z_][a-zA-Z0-9_]*)\)$/, ref_spec) do
      [_, table, column] -> {:ok, {table, column}}
      nil -> {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end
  end

  # Get schema information for collections in a specific group
  defp get_collection_schemas_for_group(group_name, collection_names) do
    collections = Collections.get_collections_for_group(group_name)

    Enum.map(collection_names, fn collection_name ->
      collection_config = Enum.find(collections, &(&1.name == collection_name))

      case get_table_schema_for_group(group_name, collection_name) do
        {:ok, schema} ->
          # Get manual references from configuration
          manual_references = (collection_config && collection_config.references) || []

          # Get automatic navigation properties from relationship discovery
          automatic_nav_props = get_automatic_navigation_properties(group_name, collection_name)

          %{
            name: collection_name,
            schema: schema,
            references: manual_references,
            navigation_properties: automatic_nav_props
          }

        {:error, _reason} ->
          # Fallback to basic schema if table doesn't exist yet
          %{
            name: collection_name,
            schema: [%{name: "Id", type: "VARCHAR"}, %{name: "Name", type: "VARCHAR"}],
            references: (collection_config && collection_config.references) || [],
            navigation_properties: []
          }
      end
    end)
  end

  # Get automatic navigation properties using relationship discovery
  defp get_automatic_navigation_properties(group_name, collection_name) do
    alias Modeta.RelationshipDiscovery

    case RelationshipDiscovery.get_navigation_properties(group_name, collection_name) do
      {:ok, nav_props} ->
        # Convert to format compatible with metadata generation
        (nav_props.belongs_to ++ nav_props.has_many)
        |> Enum.map(fn prop ->
          %{
            name: prop.name,
            target_table: prop.target_table,
            type: prop.type
          }
        end)

      _error ->
        []
    end
  end

  # Get DuckDB table schema for a collection using schema cache
  defp get_table_schema_for_group(group_name, collection_name) do
    Modeta.SchemaCache.get_schema(group_name, collection_name)
  end
end
