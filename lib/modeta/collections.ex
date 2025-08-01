defmodule Modeta.Collections do
  @moduledoc """
  Manages OData collections configuration from YAML file.
  Supports hierarchical collection groups (e.g., sales.customers, analytics.reports).
  """

  @collections_file "config/collections.yml"

  @doc """
  Loads collections configuration from YAML file.
  Returns a map with collection groups as keys and collections as values.
  """
  def load_config do
    case YamlElixir.read_from_file(@collections_file) do
      {:ok, %{"collections" => collections}} ->
        collections
        |> Enum.map(fn {group_name, group_collections} ->
          normalized_collections =
            Enum.map(group_collections, &normalize_collection(&1, group_name))

          {group_name, normalized_collections}
        end)
        |> Map.new()

      {:ok, _} ->
        raise "Invalid collections.yml format - missing 'collections' key"

      {:error, reason} ->
        raise "Failed to load collections.yml: #{inspect(reason)}"
    end
  end

  @doc """
  Gets all collection group names.
  """
  def collection_group_names do
    load_config()
    |> Map.keys()
  end

  @doc """
  Gets all collections for a specific group.
  """
  def get_collections_for_group(group_name) do
    load_config()
    |> Map.get(group_name, [])
  end

  @doc """
  Gets all collection names across all groups.
  """
  def collection_names do
    load_config()
    |> Enum.flat_map(fn {_group, collections} ->
      Enum.map(collections, & &1.name)
    end)
  end

  @doc """
  Gets all available collections (alias for collection_names).
  """
  def list_available do
    collection_names()
  end

  @doc """
  Gets the configuration for a specific collection within a group.
  """
  def get_collection(group_name, collection_name) do
    get_collections_for_group(group_name)
    |> Enum.find(&(&1.name == collection_name))
    |> case do
      nil -> {:error, :not_found}
      collection -> {:ok, collection}
    end
  end

  @doc """
  Gets the query for a specific collection within a group.
  If the collection is materialized and the table exists, returns the table name.
  Otherwise, returns the origin query for dynamic execution.
  """
  def get_query(group_name, collection_name) do
    case get_collection(group_name, collection_name) do
      {:ok, collection} -> 
        # If materialized and table exists, use the table; otherwise use origin query
        if collection.materialized and table_exists?(collection.table_name) do
          {:ok, "SELECT * FROM #{collection.table_name}"}
        else
          {:ok, collection.origin}
        end
      error -> error
    end
  end

  # Check if a materialized table exists (handles schema-qualified names)
  defp table_exists?(qualified_table_name) do
    query = case String.split(qualified_table_name, ".") do
      [schema, table] ->
        """
        SELECT 1 FROM information_schema.tables 
        WHERE table_schema = '#{schema}' AND table_name = '#{table}'
        """
        
      [table] ->
        "SELECT 1 FROM information_schema.tables WHERE table_name = '#{table}'"
        
      _ ->
        # Invalid format
        nil
    end
    
    case query do
      nil -> false
      q -> 
        case Modeta.Cache.query(q) do
          {:ok, result} ->
            rows = Modeta.Cache.to_rows(result)
            length(rows) > 0
          {:error, _} ->
            false
        end
    end
  end

  @doc """
  Gets all collections with their full configuration for data loading.
  """
  def get_all_collections_with_config do
    load_config()
    |> Enum.flat_map(fn {group_name, collections} ->
      Enum.map(collections, fn collection ->
        Map.put(collection, :group, group_name)
      end)
    end)
  end

  # Convert string keys to atom keys and ensure required fields
  defp normalize_collection(%{"name" => name, "origin" => origin} = collection, group_name) do
    materialized = Map.get(collection, "materialized", true)
    references = Map.get(collection, "references", [])
    primary_key = Map.get(collection, "primary_key", [])

    %{
      name: name,
      origin: origin,
      materialized: materialized,
      references: references,
      primary_key: primary_key,
      group: group_name,
      table_name: "#{group_name}.#{name}"
    }
  end

  defp normalize_collection(collection, _group_name) do
    raise "Invalid collection format: #{inspect(collection)}. Must have 'name' and 'origin' fields."
  end
end
