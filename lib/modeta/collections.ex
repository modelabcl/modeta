defmodule Modeta.Collections do
  @moduledoc """
  Manages OData collections configuration from YAML file.
  """

  @collections_file "config/collections.yml"

  @doc """
  Loads collections configuration from YAML file.
  Returns a list of collection maps with :name and :query keys.
  """
  def load_config do
    case YamlElixir.read_from_file(@collections_file) do
      {:ok, %{"collections" => collections}} ->
        collections
        |> Enum.map(&normalize_collection/1)

      {:ok, _} ->
        raise "Invalid collections.yml format - missing 'collections' key"

      {:error, reason} ->
        raise "Failed to load collections.yml: #{inspect(reason)}"
    end
  end

  @doc """
  Gets all collection names.
  """
  def collection_names do
    load_config()
    |> Enum.map(& &1.name)
  end

  @doc """
  Gets all available collections (alias for collection_names).
  """
  def list_available do
    collection_names()
  end

  @doc """
  Gets the query for a specific collection.
  """
  def get_query(collection_name) do
    load_config()
    |> Enum.find(&(&1.name == collection_name))
    |> case do
      nil -> {:error, :not_found}
      collection -> {:ok, collection.query}
    end
  end

  # Convert string keys to atom keys and ensure required fields
  defp normalize_collection(%{"name" => name, "query" => query}) do
    %{name: name, query: query}
  end

  defp normalize_collection(collection) do
    raise "Invalid collection format: #{inspect(collection)}. Must have 'name' and 'query' fields."
  end
end
