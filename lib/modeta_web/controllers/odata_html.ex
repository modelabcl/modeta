defmodule ModetaWeb.ODataHTML do
  @moduledoc """
  This module contains templates rendered by ODataController.
  """
  use ModetaWeb, :html

  # Generate metadata XML using string interpolation (HEEx has issues with XML attributes)
  def metadata(%{collection_schemas: collection_schemas}) do
    entity_types =
      Enum.map_join(collection_schemas, "", fn %{name: name, schema: schema} ->
        key_xml = render_key(schema)

        properties_xml = Enum.map_join(schema, "", &render_property/1)

        ~s(<EntityType Name="#{String.capitalize(name)}">#{key_xml}#{properties_xml}</EntityType>)
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
          #{entity_types}
          <EntityContainer Name="Default">
            #{entity_sets}
          </EntityContainer>
        </Schema>
      </edmx:DataServices>
    </edmx:Edmx>
    """
  end

  # Helper to render a single property
  defp render_property(%{name: prop_name, type: prop_type}) do
    nullable = if String.downcase(prop_name) == "id", do: "false", else: "true"
    ~s(<Property Name="#{prop_name}" Type="#{duckdb_type_to_odata_type(prop_type)}" Nullable="#{nullable}"/>)
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
    type = String.upcase(duckdb_type)
    do_map_type(type)
  end

  defp do_map_type(type) when type in ["BIGINT", "INTEGER", "SMALLINT", "TINYINT"], do: map_integer_type(type)
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

  defp decimal_type?(type), do: String.starts_with?(type, "DECIMAL") or String.starts_with?(type, "NUMERIC")
  defp string_type?(type), do: String.starts_with?(type, "VARCHAR") or String.starts_with?(type, "CHAR") or type == "TEXT"
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
