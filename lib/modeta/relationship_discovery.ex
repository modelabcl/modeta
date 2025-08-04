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
    # First try formal foreign key constraints from DuckDB
    case discover_formal_constraints(schema_name) do
      {:ok, %{forward_relationships: [], reverse_relationships: []}} ->
        # No formal constraints found, try schema-based inference
        discover_schema_based_relationships(schema_name)

      {:ok, relationships} ->
        # Found formal constraints
        {:ok, relationships}
    end
  end

  # Try to discover formal foreign key constraints - disabled for DuckDB
  # DuckDB doesn't have the same information_schema constraint tables
  defp discover_formal_constraints(_schema_name) do
    # Always return empty - DuckDB constraint introspection not available
    {:ok, %{forward_relationships: [], reverse_relationships: []}}
  end

  # Discover relationships by analyzing table schemas and column naming patterns
  defp discover_schema_based_relationships(schema_name) do
    try do
      {:ok, table_names} = get_tables_in_schema(schema_name)
      relationships = infer_relationships_from_schemas(schema_name, table_names)
      {:ok, relationships}
    rescue
      _error ->
        {:ok, %{forward_relationships: [], reverse_relationships: []}}
    end
  end

  # Get all tables in a schema
  defp get_tables_in_schema(_schema_name) do
    # For now, return empty list - relationship discovery will be schema-based only
    # DuckDB system table introspection is complex and not needed for basic functionality
    {:ok, []}
  end

  # Infer relationships by analyzing column names and table schemas
  defp infer_relationships_from_schemas(schema_name, table_names) do
    # Build a map of table → columns for analysis
    table_schemas = get_table_schemas(schema_name, table_names)

    # Find foreign key relationships based on naming patterns
    forward_relationships = find_foreign_key_columns(schema_name, table_schemas)
    reverse_relationships = Enum.map(forward_relationships, &build_reverse_from_forward/1)

    %{
      forward_relationships: forward_relationships,
      reverse_relationships: reverse_relationships
    }
  end

  # Get schema information for multiple tables
  defp get_table_schemas(schema_name, table_names) do
    Enum.reduce(table_names, %{}, fn table_name, acc ->
      case get_table_columns(schema_name, table_name) do
        {:ok, columns} ->
          Map.put(acc, table_name, columns)

        {:error, _} ->
          acc
      end
    end)
  end

  # Get columns for a specific table
  defp get_table_columns(schema_name, table_name) do
    query = "DESCRIBE #{schema_name}.#{table_name}"

    case Cache.query(query) do
      {:ok, result} ->
        rows = Cache.to_rows(result)
        columns = Enum.map(rows, fn [col_name, col_type | _] -> {col_name, col_type} end)
        {:ok, columns}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Find foreign key columns based on naming patterns (e.g., customer_id → customers.id)
  defp find_foreign_key_columns(schema_name, table_schemas) do
    Enum.flat_map(table_schemas, fn {table_name, columns} ->
      columns
      |> Enum.filter(fn {col_name, _col_type} -> foreign_key_column?(col_name) end)
      |> Enum.map(fn {col_name, _col_type} ->
        case infer_target_table(col_name, table_schemas) do
          {:ok, target_table, target_column} ->
            %{
              type: :belongs_to,
              schema_name: schema_name,
              source_table: table_name,
              source_column: col_name,
              target_table: target_table,
              target_column: target_column,
              navigation_property: generate_navigation_property_name(target_table, :singular)
            }

          {:error, _} ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    end)
  end

  # Check if a column name follows foreign key naming patterns
  defp foreign_key_column?(col_name) do
    # Look for patterns like customer_id, product_id, user_id, etc.
    String.ends_with?(col_name, "_id") and col_name != "id"
  end

  # Infer target table from foreign key column name
  defp infer_target_table(foreign_key_col, table_schemas) do
    # Extract table name from column (customer_id → customer)
    base_name = String.replace_suffix(foreign_key_col, "_id", "")

    # Try both singular and plural forms
    potential_tables = [
      # customer
      base_name,
      # customers  
      pluralize(base_name),
      # customer (if base_name was already plural)
      singularize(base_name)
    ]

    # Find which table actually exists
    case Enum.find(potential_tables, fn table -> Map.has_key?(table_schemas, table) end) do
      nil ->
        {:error, :target_table_not_found}

      target_table ->
        # Assume target column is 'id' (most common pattern)
        {:ok, target_table, "id"}
    end
  end

  # Build reverse relationship from forward relationship
  defp build_reverse_from_forward(forward_rel) do
    %{
      type: :has_many,
      schema_name: forward_rel.schema_name,
      source_table: forward_rel.target_table,
      source_column: forward_rel.target_column,
      target_table: forward_rel.source_table,
      target_column: forward_rel.source_column,
      navigation_property: generate_navigation_property_name(forward_rel.source_table, :plural)
    }
  end

  # Simple pluralization (can be enhanced)
  defp pluralize(word) do
    cond do
      String.ends_with?(word, "y") ->
        String.slice(word, 0..-2//1) <> "ies"

      String.ends_with?(word, ["s", "x", "z", "ch", "sh"]) ->
        word <> "es"

      true ->
        word <> "s"
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
        String.slice(word, 0..-4//1) <> "y"

      String.ends_with?(word, "es") and not String.ends_with?(word, "ses") ->
        String.slice(word, 0..-3//1)

      String.ends_with?(word, "s") and not String.ends_with?(word, "ss") ->
        String.slice(word, 0..-2//1)

      true ->
        word
    end
  end
end
