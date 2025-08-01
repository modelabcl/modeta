defmodule ModetaWeb.ODataController do
  use ModetaWeb, :controller

  alias Modeta.{Cache, Collections}

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
    content_type = get_odata_content_type(accept_header)

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
    case parse_collection_and_key(collection_with_key) do
      {:ok, collection_name, key} ->
        # Get the collection configuration to find references
        case Collections.get_collection(group_name, collection_name) do
          {:ok, collection_config} ->
            handle_navigation_request(conn, group_name, collection_config, key, nav_prop)

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
    case parse_collection_and_key(collection_param) do
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
        # Apply $filter, $expand, and $select if provided
        filter_param = Map.get(params, "$filter")
        expand_param = Map.get(params, "$expand")
        select_param = Map.get(params, "$select")

        # Build query with $expand and $select support
        final_query =
          build_query_with_options(
            base_query,
            group_name,
            collection_name,
            filter_param,
            expand_param,
            select_param
          )

        case Cache.query(final_query) do
          {:ok, result} ->
            rows = Cache.to_rows(result)
            column_names = get_column_names(result)

            # Build absolute URL for context using the group name
            base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}/#{group_name}"

            # Process expanded data if $expand was requested
            formatted_rows =
              if expand_param do
                format_rows_with_expansion(
                  rows,
                  column_names,
                  group_name,
                  collection_name,
                  expand_param
                )
              else
                format_rows_as_objects(rows, column_names)
              end

            # Build context URL with $select parameters if applicable
            context_url = build_context_url(base_url, collection_name, select_param)

            # Match JS server format - @odata.context first, then value
            response = %{
              "@odata.context" => context_url,
              "value" => formatted_rows
            }

            # Get OData content type from Accept header
            accept_header = get_req_header(conn, "accept") |> List.first()
            content_type = get_odata_content_type(accept_header)

            conn
            |> put_resp_header("odata-version", "4.0")
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
          build_query_with_options(
            entity_query,
            group_name,
            collection_name,
            nil,
            expand_param,
            select_param
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
                    format_rows_with_expansion(
                      [single_row],
                      column_names,
                      group_name,
                      collection_name,
                      expand_param
                    )
                    |> List.first()
                  else
                    format_single_row_as_object(single_row, column_names)
                  end

                # Build context URL with $select parameters if applicable
                context_url =
                  build_context_url(base_url, "#{collection_name}/$entity", select_param)

                # OData single entity response format
                response =
                  %{
                    "@odata.context" => context_url
                  }
                  |> Map.merge(entity)

                # Get OData content type from Accept header
                accept_header = get_req_header(conn, "accept") |> List.first()
                content_type = get_odata_content_type(accept_header)

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

  # Parse collection name and key from format "purchases(1)"
  defp parse_collection_and_key(collection_with_key) do
    case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_]*)\(([^)]+)\)$/, collection_with_key) do
      [_, collection_name, key] -> {:ok, collection_name, key}
      nil -> {:error, "Expected format: collection(key)"}
    end
  end

  # Handle navigation property request by finding related entities
  defp handle_navigation_request(conn, group_name, collection_config, key, nav_prop) do
    # Find the reference that matches the navigation property
    case find_reference_for_navigation(collection_config.references, nav_prop) do
      {:ok, reference} ->
        execute_navigation_query(conn, group_name, collection_config, key, reference, nav_prop)

      {:error, :no_reference} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Navigation property '#{nav_prop}' not found"}})
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

  # Execute the SQL query to get related entities
  defp execute_navigation_query(conn, group_name, collection_config, key, reference, nav_prop) do
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
            column_names = get_column_names(result)

            # Build response - navigation properties return single entity or collection
            # For now, assume single entity (most common case)
            case rows do
              [single_row] ->
                entity = format_single_row_as_object(single_row, column_names)
                base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}/#{group_name}"

                response =
                  %{
                    "@odata.context" =>
                      "#{base_url}/$metadata##{String.downcase(nav_prop)}/$entity"
                  }
                  |> Map.merge(entity)

                accept_header = get_req_header(conn, "accept") |> List.first()
                content_type = get_odata_content_type(accept_header)

                conn
                |> put_resp_header("odata-version", "4.0")
                |> put_resp_content_type(content_type)
                |> json(response)

              [] ->
                conn
                |> put_status(:not_found)
                |> json(%{error: %{message: "Related entity not found"}})

              multiple_rows ->
                # Multiple related entities - return as collection
                entities = format_rows_as_objects(multiple_rows, column_names)
                base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}/#{group_name}"

                response = %{
                  "@odata.context" => "#{base_url}/$metadata##{String.downcase(nav_prop)}",
                  "value" => entities
                }

                accept_header = get_req_header(conn, "accept") |> List.first()
                content_type = get_odata_content_type(accept_header)

                conn
                |> put_resp_header("odata-version", "4.0")
                |> put_resp_content_type(content_type)
                |> json(response)
            end

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: %{message: "Navigation query failed: #{inspect(reason)}"}})
        end

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: %{message: "Invalid reference specification: #{reason}"}})
    end
  end

  # Parse reference specification like "customers(id)" or "sales_test.customers(id)"
  defp parse_reference_spec(ref_spec) do
    case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_.]*)\(([a-zA-Z_][a-zA-Z0-9_]*)\)$/, ref_spec) do
      [_, table, column] -> {:ok, {table, column}}
      nil -> {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end
  end

  # Convert single row to object using column names
  defp format_single_row_as_object(row, column_names) do
    column_names
    |> Enum.zip(row)
    |> Enum.into(%{})
  end

  # Build OData context URL with $select parameter support
  defp build_context_url(base_url, entity_set, nil), do: "#{base_url}/$metadata##{entity_set}"

  defp build_context_url(base_url, entity_set, select_param) do
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

  # Apply $select to query by wrapping with SELECT clause containing only requested columns
  defp apply_select_to_query(base_query, select_param) do
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

  # Build query with $expand and $select support
  defp build_query_with_options(
         base_query,
         group_name,
         collection_name,
         filter_param,
         expand_param,
         select_param
       ) do
    # Get collection configuration to find references
    case Collections.get_collection(group_name, collection_name) do
      {:ok, collection_config} ->
        # Step 1: Apply $expand (LEFT JOINs) if provided
        query_with_joins =
          if expand_param do
            expanded_nav_props = String.split(expand_param, ",") |> Enum.map(&String.trim/1)
            build_joins_for_expand(base_query, collection_config, expanded_nav_props, group_name)
          else
            base_query
          end

        # Step 2: Apply $select (column filtering) if provided
        query_with_select =
          if select_param do
            apply_select_to_query(query_with_joins, select_param)
          else
            query_with_joins
          end

        # Step 3: Apply $filter last
        Modeta.ODataFilter.apply_filter_to_query(query_with_select, filter_param)

      {:error, :not_found} ->
        # Fallback: apply $select and $filter to base query
        query_with_select =
          if select_param do
            apply_select_to_query(base_query, select_param)
          else
            base_query
          end

        Modeta.ODataFilter.apply_filter_to_query(query_with_select, filter_param)
    end
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

  # Add LEFT JOIN for a specific navigation property
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

        # Get target table columns for proper aliasing
        case get_table_columns_for_expand(qualified_ref_table, join_alias) do
          {:ok, aliased_columns} ->
            # Transform base query to include LEFT JOIN with proper column aliasing
            """
            SELECT main.*, #{aliased_columns}
            FROM (#{base_query}) AS main
            LEFT JOIN #{qualified_ref_table} AS #{join_alias} 
            ON main.#{foreign_key_column} = #{join_alias}.#{ref_column}
            """

          {:error, _} ->
            # Fallback to simple join without column aliasing
            """
            SELECT main.*, #{join_alias}.*
            FROM (#{base_query}) AS main
            LEFT JOIN #{qualified_ref_table} AS #{join_alias} 
            ON main.#{foreign_key_column} = #{join_alias}.#{ref_column}
            """
        end

      {:error, _} ->
        # Skip invalid reference specifications
        base_query
    end
  end

  # Format rows with expanded navigation properties
  defp format_rows_with_expansion(rows, column_names, group_name, collection_name, expand_param) do
    # Get collection configuration to understand which columns belong to expanded entities
    case Collections.get_collection(group_name, collection_name) do
      {:ok, collection_config} ->
        expanded_nav_props = String.split(expand_param, ",") |> Enum.map(&String.trim/1)

        Enum.map(rows, fn row ->
          base_entity = format_single_row_as_object(row, column_names)

          # Add expanded navigation properties
          expanded_entity =
            Enum.reduce(expanded_nav_props, base_entity, fn nav_prop, entity ->
              case find_reference_for_navigation(collection_config.references, nav_prop) do
                {:ok, _reference} ->
                  add_expanded_property_to_entity(entity, nav_prop, row, column_names)

                {:error, :no_reference} ->
                  entity
              end
            end)

          expanded_entity
        end)

      {:error, :not_found} ->
        # Fallback to basic formatting
        format_rows_as_objects(rows, column_names)
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

  # Add expanded navigation property data to entity
  defp add_expanded_property_to_entity(entity, nav_prop, row, column_names) do
    # This is a simplified implementation
    # In a full implementation, we'd need to separate columns by table alias
    # For now, we'll create a placeholder expanded property

    # Find columns that likely belong to the expanded entity
    join_alias = String.downcase(nav_prop)

    expanded_columns =
      Enum.filter(column_names, fn col_name ->
        String.starts_with?(String.downcase(col_name), join_alias <> "_") or
          String.contains?(String.downcase(col_name), join_alias)
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
            {clean_col_name, Enum.at(row, col_index)}
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
end
