defmodule Modeta.SchemaCache do
  @moduledoc """
  In-memory cache for database schema information using ETS.
  
  Eliminates the need to create temporary views on every request
  by caching schema information (column names and types) for collections.
  
  The cache uses ETS for fast concurrent access and automatically
  handles cache invalidation when needed.
  """

  use GenServer
  require Logger

  @table_name :schema_cache
  @cache_ttl_ms 5 * 60 * 1000  # 5 minutes TTL for cached schemas

  # Public API

  @doc """
  Starts the SchemaCache GenServer and initializes the ETS table.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets cached schema for a collection, or fetches and caches it if not present.
  
  Returns {:ok, schema} where schema is a list of %{name: string, type: string}
  or {:error, reason} if the schema cannot be determined.
  """
  def get_schema(group_name, collection_name) do
    cache_key = {group_name, collection_name}
    
    case :ets.lookup(@table_name, cache_key) do
      [{^cache_key, schema, cached_at}] ->
        if cache_expired?(cached_at) do
          # Cache expired, fetch fresh schema
          fetch_and_cache_schema(group_name, collection_name)
        else
          {:ok, schema}
        end
        
      [] ->
        # Not in cache, fetch and cache
        fetch_and_cache_schema(group_name, collection_name)
    end
  end

  @doc """
  Gets cached column names for a collection.
  
  Returns a list of column name strings, or empty list if schema not available.
  """
  def get_column_names(group_name, collection_name) do
    case get_schema(group_name, collection_name) do
      {:ok, schema} ->
        Enum.map(schema, & &1.name)
        
      {:error, _reason} ->
        []
    end
  end

  @doc """
  Invalidates cached schema for a specific collection.
  
  Useful when collection structure changes.
  """
  def invalidate(group_name, collection_name) do
    cache_key = {group_name, collection_name}
    :ets.delete(@table_name, cache_key)
    :ok
  end

  @doc """
  Invalidates all cached schemas.
  
  Useful during development or when schema changes are detected.
  """
  def invalidate_all do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Warms the cache by pre-loading schemas for all known collections.
  
  Should be called during application startup to avoid cache misses
  on first requests.
  """
  def warm_cache do
    GenServer.cast(__MODULE__, :warm_cache)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Initializing SchemaCache with ETS table")
    
    # Create ETS table for concurrent read access
    :ets.new(@table_name, [
      :set,           # Each key appears once
      :public,        # Allow other processes to read
      :named_table,   # Use atom name instead of reference
      {:read_concurrency, true}  # Optimize for concurrent reads
    ])
    
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:warm_cache, state) do
    Logger.info("Starting schema cache warming...")
    
    # Warm cache in background to avoid blocking
    Task.start(fn ->
      warm_cache_for_all_collections()
    end)
    
    {:noreply, state}
  end

  # Private Functions

  defp fetch_and_cache_schema(group_name, collection_name) do
    case fetch_schema_from_database(group_name, collection_name) do
      {:ok, schema} ->
        cache_key = {group_name, collection_name}
        cached_at = System.monotonic_time(:millisecond)
        :ets.insert(@table_name, {cache_key, schema, cached_at})
        
        Logger.debug("Cached schema for #{group_name}.#{collection_name}: #{length(schema)} columns")
        {:ok, schema}
        
      error ->
        Logger.warning("Failed to fetch schema for #{group_name}.#{collection_name}: #{inspect(error)}")
        error
    end
  end

  defp fetch_schema_from_database(group_name, collection_name) do
    alias Modeta.{Collections, Cache}
    
    with {:ok, query} <- Collections.get_query(group_name, collection_name) do
      # Try to get schema without creating temp views if possible
      case get_schema_efficiently(group_name, collection_name, query) do
        {:ok, schema} ->
          {:ok, schema}
          
        {:error, _reason} ->
          # Fallback to temp view method if direct approach fails
          fetch_schema_via_temp_view(group_name, collection_name, query)
      end
    end
  end

  # Try to get schema more efficiently without temp views
  defp get_schema_efficiently(_group_name, _collection_name, query) do
    alias Modeta.Cache
    
    # If the query is a simple "SELECT * FROM table_name", 
    # we can describe the table directly
    case extract_simple_table_name(query) do
      {:ok, table_name} ->
        case Cache.describe_table(table_name) do
          {:ok, result} ->
            schema = extract_schema_from_describe(result)
            {:ok, schema}
            
          error ->
            error
        end
        
      :complex_query ->
        # Query is complex, need temp view approach
        {:error, :complex_query}
    end
  end

  # Extract table name from simple SELECT * FROM table queries
  defp extract_simple_table_name(query) do
    # Normalize whitespace and case
    normalized = query
                 |> String.trim()
                 |> String.downcase()
                 |> String.replace(~r/\s+/, " ")
    
    # Check if it's a simple "SELECT * FROM table_name" query
    case Regex.run(~r/^select \* from ([a-za-z_][a-za-z0-9_.]*)\s*$/i, normalized) do
      [_, table_name] -> {:ok, table_name}
      nil -> :complex_query
    end
  end

  # Fallback to the original temp view method
  defp fetch_schema_via_temp_view(group_name, collection_name, query) do
    alias Modeta.Cache
    
    temp_view_name = "temp_#{group_name}_#{collection_name}_schema"
    temp_query = "CREATE OR REPLACE VIEW #{temp_view_name} AS #{query}"
    
    with {:ok, _} <- Cache.query(temp_query),
         {:ok, result} <- Cache.describe_table(temp_view_name) do
      
      schema = extract_schema_from_describe(result)
      
      # Clean up temp view
      Cache.query("DROP VIEW IF EXISTS #{temp_view_name}")
      
      {:ok, schema}
    else
      error ->
        # Ensure cleanup even on error
        Cache.query("DROP VIEW IF EXISTS #{temp_view_name}")
        error
    end
  end

  # Extract schema information from DESCRIBE result (same as original)
  defp extract_schema_from_describe(result) do
    alias Modeta.Cache
    rows = Cache.to_rows(result)

    # DESCRIBE typically returns: column_name, column_type, null, key, default, extra
    # For DuckDBex, we assume the first two columns are name and type
    Enum.map(rows, fn row ->
      case row do
        [name, type | _] ->
          %{
            name: name,
            type: type
          }

        _ ->
          %{name: "unknown", type: "unknown"}
      end
    end)
  end

  defp cache_expired?(cached_at) do
    current_time = System.monotonic_time(:millisecond)
    (current_time - cached_at) > @cache_ttl_ms
  end

  defp warm_cache_for_all_collections do
    try do
      # Get all collections from all groups
      all_collections = get_all_collections()
      
      Logger.info("Warming schema cache for #{length(all_collections)} collections...")
      
      Enum.each(all_collections, fn {group_name, collection_name} ->
        case get_schema(group_name, collection_name) do
          {:ok, schema} ->
            Logger.debug("✓ Warmed cache for #{group_name}.#{collection_name} (#{length(schema)} columns)")
            
          {:error, reason} ->
            Logger.warning("✗ Failed to warm cache for #{group_name}.#{collection_name}: #{inspect(reason)}")
        end
        
        # Small delay to avoid overwhelming the database
        Process.sleep(10)
      end)
      
      Logger.info("Schema cache warming completed")
      
    rescue
      error ->
        Logger.error("Schema cache warming failed: #{inspect(error)}")
    end
  end

  defp get_all_collections do
    try do
      # Get all collection groups
      groups = Modeta.Collections.collection_group_names()
      
      Enum.flat_map(groups, fn group_name ->
        collections = Modeta.Collections.get_collections_for_group(group_name)
        Enum.map(collections, fn collection ->
          {group_name, collection.name}
        end)
      end)
    rescue
      _error ->
        # Return empty list if we can't get collections
        # (might happen during startup before data is loaded)
        []
    end
  end
end