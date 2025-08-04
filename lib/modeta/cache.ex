defmodule Modeta.Cache do
  @moduledoc """
  Cache module for DuckDB queries using DuckDBex connection.
  Provides functionality to execute SQL queries against DuckDB.
  """

  use GenServer
  require Logger

  @doc """
  Starts the DuckDB cache GenServer.
  """
  def start_link(ddb) do
    GenServer.start_link(__MODULE__, ddb, name: __MODULE__)
  end

  @doc """
  Executes a SQL query using DuckDBex connection.
  Returns {:ok, result} on success or {:error, reason} on failure.
  """
  def query(sql) when is_binary(sql) do
    require Logger

    # Debug log every SQL query
    Logger.debug("[SQL DEBUG] Executing query: #{sql}")

    start_time = System.monotonic_time(:millisecond)

    result = GenServer.call(__MODULE__, {:query, sql}, 30_000)

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    case result do
      {:ok, %{data: data}} ->
        row_count = length(data)
        Logger.debug("[SQL DEBUG] Query completed in #{duration}ms, returned #{row_count} rows")
        {:ok, %{data: data}}

      error ->
        Logger.error("[SQL DEBUG] Query failed after #{duration}ms: #{inspect(error)}")
        error
    end
  end

  # GenServer Callbacks

  @impl true
  def init(ddb) do
    Logger.info("DuckDB Cache GenServer initialized with database reference")
    {:ok, %{db: ddb}}
  end

  @impl true
  def handle_call({:query, sql}, _from, %{db: ddb} = state) do
    result =
      case Duckdbex.connection(ddb) do
        {:ok, conn} ->
          case Duckdbex.query(conn, sql) do
            {:ok, query_result} ->
              # Fetch all results - returns data directly, not {:ok, data}
              data = Duckdbex.fetch_all(query_result)
              {:ok, %{data: data}}

            error ->
              error
          end

        error ->
          error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_database, _from, %{db: ddb} = state) do
    {:reply, {:ok, ddb}, state}
  end

  @impl true
  def terminate(_reason, %{db: _ddb}) do
    # DuckDB database and connections close automatically when process terminates
    :ok
  end

  @doc """
  Loads a CSV file into DuckDB and returns the table name.
  """
  def load_csv(file_path, table_name \\ nil) do
    table_name = table_name || Path.basename(file_path, ".csv")
    absolute_path = Path.expand(file_path)

    sql = """
    CREATE OR REPLACE TABLE #{table_name} AS
    SELECT * FROM read_csv_auto('#{absolute_path}')
    """

    case query(sql) do
      {:ok, _} -> {:ok, table_name}
      error -> error
    end
  end

  @doc """
  Executes a SELECT query on a table.
  """
  def select(table_name, columns \\ "*", where_clause \\ nil) do
    sql = "SELECT #{columns} FROM #{table_name}"
    sql = if where_clause, do: "#{sql} WHERE #{where_clause}", else: sql

    query(sql)
  end

  @doc """
  Gets table information including column names and types.
  """
  def describe_table(table_name) do
    query("DESCRIBE #{table_name}")
  end

  @doc """
  Converts DuckDBex result to rows format for easier data access.
  Returns list of lists where each inner list represents a row.
  DuckDBex already returns data in this format.
  """
  def to_rows(%{data: data}) do
    data
  end

  @doc """
  Gets column names from DuckDBex result.
  For DuckDBex, we need to get column names separately.
  """
  def get_column_names(table_name) when is_binary(table_name) do
    case query("DESCRIBE #{table_name}") do
      {:ok, %{data: rows}} ->
        Enum.map(rows, fn [col_name | _] -> col_name end)

      {:error, _} ->
        []
    end
  end
end
