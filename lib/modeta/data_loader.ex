defmodule Modeta.DataLoader do
  @moduledoc """
  Loads data from various sources into DuckDB for OData access.
  Automatically creates schemas and tables/views based on collections configuration.
  """

  alias Modeta.Cache
  alias Modeta.Collections

  require Logger

  @doc """
  Initialize all data sources by creating schemas and tables/views for all collections.
  Only creates missing tables/views - existing ones are left unchanged.
  """
  def initialize do
    Logger.info("Starting data initialization...")

    case create_all_schemas_and_tables() do
      :ok ->
        Logger.info("✓ Data initialization complete")
        :ok

      {:error, reason} ->
        Logger.error("✗ Data initialization failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Create all schemas and tables/views for collections that don't already exist.
  """
  def create_all_schemas_and_tables do
    collections = Collections.get_all_collections_with_config()

    with :ok <- create_schemas(collections),
         :ok <- create_tables_and_views(collections) do
      :ok
    end
  end

  @doc """
  Check if a table exists in DuckDB.
  """
  def table_exists?(table_name) do
    query = "SELECT 1 FROM information_schema.tables WHERE table_name = '#{table_name}'"

    case Cache.query(query) do
      {:ok, result} ->
        rows = Cache.to_rows(result)
        length(rows) > 0

      {:error, _} ->
        false
    end
  end

  @doc """
  Check if a schema exists in DuckDB.
  """
  def schema_exists?(schema_name) do
    query = "SELECT 1 FROM information_schema.schemata WHERE schema_name = '#{schema_name}'"

    case Cache.query(query) do
      {:ok, result} ->
        rows = Cache.to_rows(result)
        length(rows) > 0

      {:error, _} ->
        false
    end
  end

  # Create all required schemas
  defp create_schemas(collections) do
    collections
    |> Enum.map(& &1.group)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn schema_name, :ok ->
      if schema_exists?(schema_name) do
        Logger.debug("Schema '#{schema_name}' already exists, skipping")
        {:cont, :ok}
      else
        case create_schema(schema_name) do
          :ok ->
            Logger.info("✓ Created schema '#{schema_name}'")
            {:cont, :ok}

          {:error, reason} ->
            Logger.error("✗ Failed to create schema '#{schema_name}': #{inspect(reason)}")
            {:halt, {:error, reason}}
        end
      end
    end)
  end

  # Create individual schema
  defp create_schema(schema_name) do
    query = "CREATE SCHEMA IF NOT EXISTS #{schema_name}"

    case Cache.query(query) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Create all tables and views
  defp create_tables_and_views(collections) do
    Enum.reduce_while(collections, :ok, fn collection, :ok ->
      full_table_name = "#{collection.group}.#{collection.name}"

      if table_exists?(collection.name) do
        Logger.debug("Table '#{full_table_name}' already exists, skipping")
        {:cont, :ok}
      else
        case create_table_or_view(collection) do
          :ok ->
            type = if collection.materialized, do: "table", else: "view"
            Logger.info("✓ Created #{type} '#{full_table_name}'")
            {:cont, :ok}

          {:error, reason} ->
            Logger.error("✗ Failed to create table/view '#{full_table_name}': #{inspect(reason)}")
            {:halt, {:error, reason}}
        end
      end
    end)
  end

  # Create table or view based on materialized flag
  defp create_table_or_view(%{materialized: true} = collection) do
    create_materialized_table_with_constraints(collection)
  end

  defp create_table_or_view(%{materialized: false} = collection) do
    query = "CREATE VIEW IF NOT EXISTS #{collection.table_name} AS (#{collection.origin})"
    execute_creation_query(query)
  end

  # Create materialized table with foreign key constraints defined at creation time
  defp create_materialized_table_with_constraints(%{references: [], primary_key: []} = collection) do
    # Simple case: no constraints at all, create table as before
    query = "CREATE TABLE IF NOT EXISTS #{collection.table_name} AS (#{collection.origin})"
    execute_creation_query(query)
  end

  defp create_materialized_table_with_constraints(%{references: []} = collection) do
    # Case: primary key only, no foreign keys
    with {:ok, temp_table} <- create_temp_table_for_schema_inference(collection),
         {:ok, columns} <- get_table_columns(temp_table),
         :ok <- drop_temp_table(temp_table),
         :ok <- create_table_with_explicit_schema(collection, columns, []) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Could not create table with primary key constraints, falling back to simple table creation: #{inspect(reason)}")
        # Fallback to simple table creation
        query = "CREATE TABLE IF NOT EXISTS #{collection.table_name} AS (#{collection.origin})"
        execute_creation_query(query)
    end
  end

  defp create_materialized_table_with_constraints(%{references: references} = collection) do
    # Complex case: need to create table with explicit schema and foreign keys
    with {:ok, temp_table} <- create_temp_table_for_schema_inference(collection),
         {:ok, columns} <- get_table_columns(temp_table),
         :ok <- drop_temp_table(temp_table),
         :ok <- create_table_with_explicit_schema(collection, columns, references) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Could not create table with foreign key constraints, falling back to simple table creation: #{inspect(reason)}")
        # Fallback to simple table creation
        query = "CREATE TABLE IF NOT EXISTS #{collection.table_name} AS (#{collection.origin})"
        execute_creation_query(query)
    end
  end

  # Create temporary table to infer schema
  defp create_temp_table_for_schema_inference(%{table_name: table_name, origin: origin}) do
    temp_table = "temp_schema_#{table_name |> String.replace(".", "_")}_#{:rand.uniform(10000)}"
    query = "CREATE TEMP TABLE #{temp_table} AS (#{origin})"
    
    case Cache.query(query) do
      {:ok, _} -> {:ok, temp_table}
      {:error, reason} -> {:error, reason}
    end
  end

  # Get column information from temporary table
  defp get_table_columns(temp_table) do
    query = "DESCRIBE #{temp_table}"
    
    case Cache.query(query) do
      {:ok, result} ->
        rows = Cache.to_rows(result)
        columns = Enum.map(rows, fn row ->
          # DESCRIBE returns a list where each row is a list of values
          # DuckDB DESCRIBE format: [column_name, column_type, null, key, default, extra]
          case row do
            [name, type | _] when is_binary(name) and is_binary(type) -> 
              %{name: name, type: type}
            _ -> 
              Logger.warning("Unexpected DESCRIBE row format: #{inspect(row)}")
              %{name: "unknown", type: "VARCHAR"}
          end
        end)
        {:ok, columns}
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Drop temporary table
  defp drop_temp_table(temp_table) do
    query = "DROP TABLE #{temp_table}"
    case Cache.query(query) do
      {:ok, _} -> :ok
      {:error, _} -> :ok  # Ignore errors when dropping temp tables
    end
  end

  # Create table with explicit schema and foreign key constraints
  defp create_table_with_explicit_schema(%{table_name: table_name, origin: origin, group: group, primary_key: primary_key}, columns, references) do
    # Build column definitions
    column_defs = Enum.map_join(columns, ", ", fn %{name: name, type: type} ->
      "#{name} #{type}"
    end)
    
    # Build primary key constraint
    pk_constraint = if length(primary_key) > 0 do
      pk_columns = Enum.join(primary_key, ", ")
      "PRIMARY KEY (#{pk_columns})"
    else
      ""
    end
    
    # Build foreign key constraints with proper schema qualification
    fk_constraints = Enum.map_join(references, ", ", fn %{"col" => column, "ref" => ref_spec} ->
      case parse_reference_spec(ref_spec) do
        {:ok, {ref_table, ref_column}} ->
          # Ensure reference table has schema prefix if not already present
          qualified_ref_table = if String.contains?(ref_table, ".") do
            ref_table
          else
            "#{group}.#{ref_table}"
          end
          "FOREIGN KEY (#{column}) REFERENCES #{qualified_ref_table}(#{ref_column})"
        {:error, _} ->
          ""
      end
    end)
    |> String.trim_trailing(", ")
    
    # Combine all constraints
    all_constraints = [pk_constraint, fk_constraints]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
    
    constraints = if all_constraints != "", do: ", #{all_constraints}", else: ""
    
    # Create table with explicit schema and constraints
    create_query = "CREATE TABLE IF NOT EXISTS #{table_name} (#{column_defs}#{constraints})"
    
    with :ok <- execute_creation_query(create_query),
         :ok <- populate_table_with_data(table_name, origin) do
      constraint_info = if pk_constraint != "" and fk_constraints != "" do
        "primary key and foreign key constraints"
      else
        if pk_constraint != "", do: "primary key constraints", else: "foreign key constraints"
      end
      Logger.info("✓ Created table '#{table_name}' with #{constraint_info}")
      :ok
    end
  end

  # Populate table with data from origin query
  defp populate_table_with_data(table_name, origin) do
    query = "INSERT INTO #{table_name} (#{origin})"
    execute_creation_query(query)
  end

  # Parse reference specification like "customers(id)" or "sales_test.customers(id)"
  defp parse_reference_spec(ref_spec) do
    case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_.]*)\(([a-zA-Z_][a-zA-Z0-9_]*)\)$/, ref_spec) do
      [_, table, column] -> {:ok, {table, column}}
      nil -> {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end
  end

  # Execute the table/view creation query
  defp execute_creation_query(query) do
    case Cache.query(query) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Refresh materialized tables (recreate them with fresh data).
  Views are automatically refreshed since they're not materialized.
  """
  def refresh_materialized_tables do
    Logger.info("Refreshing materialized tables...")

    Collections.get_all_collections_with_config()
    |> Enum.filter(& &1.materialized)
    |> Enum.each(fn collection ->
      Logger.info("Refreshing table '#{collection.table_name}'")

      drop_query = "DROP TABLE IF EXISTS #{collection.table_name}"
      create_query = "CREATE TABLE #{collection.table_name} AS (#{collection.origin})"

      with {:ok, _} <- Cache.query(drop_query),
           {:ok, _} <- Cache.query(create_query) do
        Logger.info("✓ Refreshed table '#{collection.table_name}'")
      else
        {:error, reason} ->
          Logger.error("✗ Failed to refresh table '#{collection.table_name}': #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Legacy function for initial data loading (kept for backward compatibility).
  """
  def load_initial_data do
    Logger.warning("load_initial_data/0 is deprecated. Use initialize/0 instead.")
    initialize()
  end

  @doc """
  Legacy function for customers data loading (kept for backward compatibility).
  """
  def load_customers_data do
    Logger.warning("load_customers_data/0 is deprecated. Use initialize/0 instead.")
    initialize()
  end
end
