defmodule ModetaWeb.ODataHTML do
  @moduledoc """
  This module contains templates rendered by ODataController.
  """
  use ModetaWeb, :html

  # Generate metadata XML using string interpolation (HEEx has issues with XML attributes)
  def metadata(%{collection_schemas: collection_schemas}) do
    entity_types = 
      Enum.map(collection_schemas, fn %{name: name, schema: schema} ->
        key_xml = render_key(schema)
        properties_xml = 
          Enum.map(schema, fn %{name: prop_name, type: prop_type} ->
            nullable = if String.downcase(prop_name) == "id", do: "false", else: "true"
            ~s(<Property Name="#{prop_name}" Type="#{duckdb_type_to_odata_type(prop_type)}" Nullable="#{nullable}"/>)
          end)
          |> Enum.join("")
        
        ~s(<EntityType Name="#{String.capitalize(name)}">#{key_xml}#{properties_xml}</EntityType>)
      end)
      |> Enum.join("")

    entity_sets = 
      Enum.map(collection_schemas, fn %{name: name} ->
        ~s(<EntitySet Name="#{name}" EntityType="Default.#{String.capitalize(name)}"/>)
      end)
      |> Enum.join("")

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
      <edmx:DataServices>
        <Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Default">
          #{entity_types}
          <EntityContainer Name="Default">
            #{entity_sets}
          </EntityContainer>
        </Schema>
      </edmx:DataServices>
    </edmx:Edmx>
    """
  end

  # Render Key element for EntityType (assumes first field named 'id' or 'Id' is the key)
  def render_key(schema) do
    key_field = Enum.find(schema, fn %{name: name} -> 
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
    case String.upcase(duckdb_type) do
      "BIGINT" -> "Edm.Int64"
      "INTEGER" -> "Edm.Int32"
      "SMALLINT" -> "Edm.Int16"
      "TINYINT" -> "Edm.Byte"
      "DOUBLE" -> "Edm.Double"
      "REAL" -> "Edm.Single"
      "FLOAT" -> "Edm.Single"
      "DECIMAL" <> _ -> "Edm.Decimal"
      "NUMERIC" <> _ -> "Edm.Decimal"
      "VARCHAR" <> _ -> "Edm.String"
      "CHAR" <> _ -> "Edm.String"
      "TEXT" -> "Edm.String"
      "BOOLEAN" -> "Edm.Boolean"
      "DATE" -> "Edm.Date"
      "TIME" -> "Edm.TimeOfDay"
      "TIMESTAMP" -> "Edm.DateTimeOffset"
      "TIMESTAMPTZ" -> "Edm.DateTimeOffset"
      "UUID" -> "Edm.Guid"
      "BLOB" -> "Edm.Binary"
      # Default fallback
      _ -> "Edm.String"
    end
  end
end