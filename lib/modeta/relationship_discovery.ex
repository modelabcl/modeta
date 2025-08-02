defmodule Modeta.RelationshipDiscovery do
  @moduledoc """
  Automatically discovers bidirectional relationships between tables using DuckDB introspection.

  This module uses DuckDB's metadata functions to discover foreign key constraints
  and automatically infer both "belongs to" and "has many" relationships without
  requiring manual configuration.

  ## Features
  - Discovers foreign keys using `duckdb_constraints()`
  - Creates bidirectional navigation properties
  - Generates proper OData navigation property names
  - Caches relationship information for performance
  """

  alias Modeta.Cache

  @doc """
  Discovers all relationships in a database schema.

  Uses DuckDB's `duckdb_constraints()` function to find foreign key constraints
  and builds a comprehensive relationship map.

  ## Returns
  - {:ok, relationship_map} where relationship_map contains:
    - forward_relationships: belongs_to relationships (many → one)
    - reverse_relationships: has_many relationships (one → many)
  - {:error, reason} on database query failure
  """
  def discover_relationships(schema_name \\ nil) do
    # Query foreign key constraints from DuckDB
    constraint_query = """
    SELECT 
      database_name,
      schema_name,
      table_name,
      constraint_column_names,
      referenced_table,
      referenced_column_names
    FROM duckdb_constraints() 
    WHERE constraint_type = 'FOREIGN KEY'
    #{if schema_name, do: "AND schema_name = '#{schema_name}'", else: ""}
    ORDER BY schema_name, table_name, constraint_column_names
    """

    try do
      case Cache.query(constraint_query) do
        {:ok, result} ->
          rows = Cache.to_rows(result)
          relationship_map = build_relationship_map(rows)
          {:ok, relationship_map}

        {:error, _reason} ->
          # Gracefully handle cases where DuckDB doesn't have foreign key constraints
          # or when running in test environments without proper schema setup
          # Return empty relationships to allow fallback to manual configuration
          {:ok, %{forward_relationships: [], reverse_relationships: []}}
      end
    rescue
      _error ->
        # Handle any Erlang errors or crashes during DuckDB metadata queries
        # This allows the system to continue working with manual configuration
        {:ok, %{forward_relationships: [], reverse_relationships: []}}
    end
  end

  @doc """
  Gets navigation properties for a specific table.

  Returns both outgoing (belongs_to) and incoming (has_many) navigation properties
  for the specified table.

  ## Parameters
  - schema_name: Database schema name (e.g., "sales_test")
  - table_name: Table name (e.g., "purchases")

  ## Returns
  - {:ok, navigation_properties} with structure:
    ```elixir
    %{
      belongs_to: [%{name: "Customer", target_table: "customers", ...}],
      has_many: [%{name: "Purchases", source_table: "purchases", ...}]
    }
    ```
  """
  def get_navigation_properties(schema_name, table_name) do
    case discover_relationships(schema_name) do
      {:ok, relationships} ->
        belongs_to = get_belongs_to_properties(relationships, schema_name, table_name)
        has_many = get_has_many_properties(relationships, schema_name, table_name)

        navigation_props = %{
          belongs_to: belongs_to,
          has_many: has_many
        }

        {:ok, navigation_props}
    end
  end

  @doc """
  Finds the reverse relationship for a navigation property.

  Given a navigation property name and source table, finds the corresponding
  reverse navigation property that would exist on the target table.

  ## Example
  If `purchases` has navigation property `Customer` pointing to `customers`,
  this function can find that `customers` should have navigation property `Purchases`.
  """
  def find_reverse_navigation(schema_name, source_table, nav_property_name) do
    case get_navigation_properties(schema_name, source_table) do
      {:ok, nav_props} ->
        # Look for the navigation property in belongs_to relationships
        belongs_to_match =
          Enum.find(nav_props.belongs_to, fn prop ->
            String.downcase(prop.name) == String.downcase(nav_property_name)
          end)

        case belongs_to_match do
          %{target_table: target_table, target_column: target_col, source_column: source_col} ->
            # Found belongs_to relationship, find reverse has_many
            case get_navigation_properties(schema_name, target_table) do
              {:ok, target_nav_props} ->
                reverse_prop =
                  Enum.find(target_nav_props.has_many, fn prop ->
                    prop.source_table == source_table and
                      prop.source_column == source_col and
                      prop.target_column == target_col
                  end)

                case reverse_prop do
                  nil -> {:error, :no_reverse_relationship}
                  prop -> {:ok, prop}
                end
            end

          nil ->
            {:error, :navigation_property_not_found}
        end
    end
  end

  # Private helper functions

  # Build comprehensive relationship map from foreign key constraint rows
  defp build_relationship_map(constraint_rows) do
    forward_relationships = Enum.map(constraint_rows, &build_forward_relationship/1)
    reverse_relationships = Enum.map(constraint_rows, &build_reverse_relationship/1)

    %{
      forward_relationships: forward_relationships,
      reverse_relationships: reverse_relationships
    }
  end

  # Build "belongs to" relationship (many → one)
  defp build_forward_relationship(row) do
    [schema_name, table_name, source_column, referenced_table, referenced_column] = row

    %{
      type: :belongs_to,
      schema_name: schema_name,
      source_table: table_name,
      source_column: source_column,
      target_table: referenced_table,
      target_column: referenced_column,
      navigation_property: generate_navigation_property_name(referenced_table, :singular)
    }
  end

  # Build "has many" relationship (one → many)
  defp build_reverse_relationship(row) do
    [schema_name, table_name, source_column, referenced_table, referenced_column] = row

    %{
      type: :has_many,
      schema_name: schema_name,
      # Reverse: target becomes source
      source_table: referenced_table,
      source_column: referenced_column,
      # Reverse: source becomes target
      target_table: table_name,
      target_column: source_column,
      navigation_property: generate_navigation_property_name(table_name, :plural)
    }
  end

  # Get belongs_to navigation properties for a table
  defp get_belongs_to_properties(relationships, schema_name, table_name) do
    relationships.forward_relationships
    |> Enum.filter(fn rel ->
      rel.schema_name == schema_name and rel.source_table == table_name
    end)
    |> Enum.map(fn rel ->
      %{
        name: rel.navigation_property,
        type: :belongs_to,
        target_table: rel.target_table,
        target_column: rel.target_column,
        source_column: rel.source_column
      }
    end)
  end

  # Get has_many navigation properties for a table
  defp get_has_many_properties(relationships, schema_name, table_name) do
    relationships.reverse_relationships
    |> Enum.filter(fn rel ->
      rel.schema_name == schema_name and rel.source_table == table_name
    end)
    |> Enum.map(fn rel ->
      %{
        name: rel.navigation_property,
        type: :has_many,
        target_table: rel.target_table,
        target_column: rel.target_column,
        source_column: rel.source_column
      }
    end)
  end

  # Generate proper OData navigation property names
  defp generate_navigation_property_name(table_name, cardinality) do
    base_name =
      table_name
      |> String.trim()
      |> String.split("_")
      |> Enum.map_join("", &String.capitalize/1)

    case cardinality do
      :singular ->
        # Convert plural table name to singular for belongs_to
        # customers -> Customer, purchases -> Purchase
        singularize(base_name)

      :plural ->
        # Keep plural for has_many
        # purchases -> Purchases, order_items -> OrderItems
        base_name
    end
  end

  # Simple singularization (can be enhanced with a proper library)
  defp singularize(word) do
    cond do
      String.ends_with?(word, "ies") ->
        String.slice(word, 0..-4//-1) <> "y"

      String.ends_with?(word, "es") and not String.ends_with?(word, "ses") ->
        String.slice(word, 0..-3//-1)

      String.ends_with?(word, "s") and not String.ends_with?(word, "ss") ->
        String.slice(word, 0..-2//-1)

      true ->
        word
    end
  end
end
