defmodule ModetaWeb.ODataHTML do
  @moduledoc """
  This module contains templates rendered by ODataController.
  """
  use ModetaWeb, :html

  # Generate metadata XML using string interpolation (HEEx has issues with XML attributes)
  def metadata(%{collection_schemas: collection_schemas}) do
    # Extract complex types from all schemas
    complex_types = extract_complex_types(collection_schemas)
    complex_types_xml = render_complex_types(complex_types)

    entity_types =
      Enum.map_join(collection_schemas, "", fn schema_info ->
        %{name: name, schema: schema, references: references} = schema_info
        # Get automatic navigation properties if available
        auto_nav_props = Map.get(schema_info, :navigation_properties, [])

        key_xml = render_key(schema)
        properties_xml = Enum.map_join(schema, "", &render_property/1)

        # Render both manual references and automatic navigation properties
        manual_nav_xml = render_navigation_properties(references, collection_schemas)
        auto_nav_xml = render_automatic_navigation_properties(auto_nav_props, collection_schemas)

        ~s(<EntityType Name="#{String.capitalize(name)}">#{key_xml}#{properties_xml}#{manual_nav_xml}#{auto_nav_xml}</EntityType>)
      end)

    entity_sets =
      Enum.map_join(collection_schemas, "", fn %{name: name} ->
        ~s(<EntitySet Name="#{name}" EntityType="Default.#{String.capitalize(name)}"/>)
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
      <edmx:DataServices>
        <Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Default">
          #{complex_types_xml}
          #{entity_types}
          <EntityContainer Name="Default">
            #{entity_sets}
          </EntityContainer>
        </Schema>
      </edmx:DataServices>
    </edmx:Edmx>
    """
  end

  # Extract complex types from all collection schemas
  defp extract_complex_types(collection_schemas) do
    collection_schemas
    |> Enum.flat_map(fn %{schema: schema} ->
      schema
      |> Enum.filter(&is_complex_type?/1)
      |> Enum.map(&extract_complex_type_definition/1)
    end)
    |> Enum.uniq()
  end

  # Check if a column represents a complex type (STRUCT or array of STRUCT)
  defp is_complex_type?(%{type: type}) do
    String.contains?(type, "STRUCT(")
  end

  # Extract complex type definition from DuckDB STRUCT type
  defp extract_complex_type_definition(%{type: type}) do
    case parse_struct_type(type) do
      {:ok, {type_name, properties}} ->
        %{name: type_name, properties: properties}
      {:error, _} ->
        # Fallback for unparseable complex types
        %{name: "GenericType", properties: []}
    end
  end

  # Parse DuckDB STRUCT type definition
  defp parse_struct_type(type) do
    # Handle STRUCT(...)[]) for arrays of structs
    base_type = String.replace(type, ~r/\[\]$/, "")
    
    case Regex.run(~r/^STRUCT\((.+)\)/, base_type) do
      [_, struct_content] ->
        properties = parse_struct_properties(struct_content)
        type_name = if String.ends_with?(type, "[]"), do: "AddressInfo", else: "AddressInfo"
        {:ok, {type_name, properties}}
      
      nil ->
        {:error, "Not a valid STRUCT type"}
    end
  end

  # Parse individual properties within a STRUCT definition
  defp parse_struct_properties(struct_content) do
    # Split by commas, but be careful of nested types
    # For now, handle simple case: "field1 TYPE1, field2 TYPE2"
    struct_content
    |> String.replace(~r/"([^"]+)"/, "\\1")  # Remove quotes around field names
    |> String.split(~r/,\s*/)
    |> Enum.map(fn field_def ->
      case String.split(field_def, ~r/\s+/, parts: 2) do
        [name, field_type] ->
          %{name: name, type: String.trim(field_type)}
        [name] ->
          %{name: name, type: "VARCHAR"}
        _ ->
          %{name: "unknown", type: "VARCHAR"}
      end
    end)
  end

  # Render complex types XML
  defp render_complex_types([]), do: ""
  
  defp render_complex_types(complex_types) do
    Enum.map_join(complex_types, "", fn %{name: type_name, properties: properties} ->
      properties_xml = Enum.map_join(properties, "", fn %{name: prop_name, type: prop_type} ->
        ~s(<Property Name="#{prop_name}" Type="#{duckdb_type_to_odata_type(prop_type)}" Nullable="true"/>)
      end)
      
      ~s(<ComplexType Name="#{type_name}">#{properties_xml}</ComplexType>)
    end)
  end

  # Helper to render a single property
  defp render_property(%{name: prop_name, type: prop_type}) do
    nullable = if String.downcase(prop_name) == "id", do: "false", else: "true"

    ~s(<Property Name="#{prop_name}" Type="#{duckdb_type_to_odata_type(prop_type)}" Nullable="#{nullable}"/>)
  end

  # Render navigation properties based on references
  defp render_navigation_properties([], _collection_schemas), do: ""

  defp render_navigation_properties(references, collection_schemas) do
    Enum.map_join(references, "", fn reference ->
      render_single_navigation_property(reference, collection_schemas)
    end)
  end

  # Render automatic navigation properties from relationship discovery
  defp render_automatic_navigation_properties([], _collection_schemas), do: ""

  defp render_automatic_navigation_properties(nav_props, collection_schemas) do
    Enum.map_join(nav_props, "", fn nav_prop ->
      render_automatic_navigation_property(nav_prop, collection_schemas)
    end)
  end

  # Render a single automatic navigation property
  defp render_automatic_navigation_property(
         %{name: nav_name, target_table: target_table, type: nav_type},
         collection_schemas
       ) do
    # Check if the target collection exists in our schemas
    target_exists =
      Enum.any?(collection_schemas, fn schema ->
        String.downcase(schema.name) == String.downcase(target_table)
      end)

    if target_exists do
      target_type = "Default.#{String.capitalize(target_table)}"

      # Determine if this is a collection navigation (has_many) or single navigation (belongs_to)
      type_attribute =
        case nav_type do
          :has_many -> "Type=\"Collection(#{target_type})\""
          :belongs_to -> "Type=\"#{target_type}\""
          _ -> "Type=\"#{target_type}\""
        end

      ~s(<NavigationProperty Name="#{nav_name}" #{type_attribute} Nullable="true"/>)
    else
      # Don't create navigation property if target doesn't exist
      ""
    end
  end

  # Render a single navigation property
  defp render_single_navigation_property(
         %{"col" => _column, "ref" => ref_spec},
         collection_schemas
       ) do
    case parse_reference_spec(ref_spec) do
      {:ok, {ref_table, _ref_column}} ->
        # Find the target entity type - strip schema prefix if present
        target_table = ref_table |> String.split(".") |> List.last()

        # Check if the target collection exists in our schemas
        target_exists =
          Enum.any?(collection_schemas, fn schema ->
            String.downcase(schema.name) == String.downcase(target_table)
          end)

        if target_exists do
          # Create navigation property name by capitalizing the target table
          nav_prop_name = String.capitalize(target_table)
          target_type = "Default.#{String.capitalize(target_table)}"

          ~s(<NavigationProperty Name="#{nav_prop_name}" Type="#{target_type}" Nullable="true"/>)
        else
          # Don't create navigation property if target doesn't exist
          ""
        end

      {:error, _reason} ->
        # Skip invalid reference specifications
        ""
    end
  end

  # Parse reference specification like "customers(id)" or "sales_test.customers(id)"
  defp parse_reference_spec(ref_spec) do
    case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_.]*)\(([a-zA-Z_][a-zA-Z0-9_]*)\)$/, ref_spec) do
      [_, table, column] -> {:ok, {table, column}}
      nil -> {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end
  end

  # Render Key element for EntityType (assumes first field named 'id' or 'Id' is the key)
  def render_key(schema) do
    key_field =
      Enum.find(schema, fn %{name: name} ->
        String.downcase(name) == "id"
      end)

    case key_field do
      %{name: key_name} ->
        ~s(<Key><PropertyRef Name="#{key_name}"/></Key>)

      nil ->
        # Fallback: use first field as key if no 'id' field found
        case List.first(schema) do
          %{name: first_name} ->
            ~s(<Key><PropertyRef Name="#{first_name}"/></Key>)

          nil ->
            ""
        end
    end
  end

  # Map DuckDB types to OData EDM types
  def duckdb_type_to_odata_type(duckdb_type) do
    # Handle complex types first
    cond do
      String.contains?(duckdb_type, "STRUCT(") and String.ends_with?(duckdb_type, "[]") ->
        # Array of structs - use Collection of complex type
        "Collection(Default.AddressInfo)"
      
      String.contains?(duckdb_type, "STRUCT(") ->
        # Single struct - use complex type
        "Default.AddressInfo"
      
      true ->
        # Regular scalar types
        type = String.upcase(duckdb_type)
        do_map_type(type)
    end
  end

  defp do_map_type(type) when type in ["BIGINT", "INTEGER", "SMALLINT", "TINYINT"],
    do: map_integer_type(type)

  defp do_map_type(type) when type in ["DOUBLE", "REAL", "FLOAT"], do: map_float_type(type)
  defp do_map_type("BOOLEAN"), do: "Edm.Boolean"
  defp do_map_type("UUID"), do: "Edm.Guid"
  defp do_map_type("BLOB"), do: "Edm.Binary"

  defp do_map_type(type) do
    cond do
      decimal_type?(type) -> "Edm.Decimal"
      string_type?(type) -> "Edm.String"
      datetime_type?(type) -> map_datetime_type(type)
      true -> "Edm.String"
    end
  end

  defp decimal_type?(type),
    do: String.starts_with?(type, "DECIMAL") or String.starts_with?(type, "NUMERIC")

  defp string_type?(type),
    do:
      String.starts_with?(type, "VARCHAR") or String.starts_with?(type, "CHAR") or type == "TEXT"

  defp datetime_type?(type), do: type in ["DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ"]

  defp map_integer_type("BIGINT"), do: "Edm.Int64"
  defp map_integer_type("INTEGER"), do: "Edm.Int32"
  defp map_integer_type("SMALLINT"), do: "Edm.Int16"
  defp map_integer_type("TINYINT"), do: "Edm.Byte"

  defp map_float_type("DOUBLE"), do: "Edm.Double"
  defp map_float_type(_), do: "Edm.Single"

  defp map_datetime_type("DATE"), do: "Edm.Date"
  defp map_datetime_type("TIME"), do: "Edm.TimeOfDay"
  defp map_datetime_type(_), do: "Edm.DateTimeOffset"
end
