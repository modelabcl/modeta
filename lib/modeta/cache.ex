defmodule Modeta.Cache do
  @moduledoc """
  Cache module for DuckDB queries using ADBC connection.
  Provides functionality to execute SQL queries against DuckDB.
  """

  @doc """
  Executes a SQL query using the named ADBC connection.
  Returns {:ok, result} on success or {:error, reason} on failure.
  """
  def query(sql) when is_binary(sql) do
    require Logger

    # Debug log every SQL query
    Logger.debug("[SQL DEBUG] Executing query: #{sql}")

    start_time = System.monotonic_time(:millisecond)

    case Adbc.Connection.query(Modeta.Conn, sql) do
      {:ok, result} ->
        end_time = System.monotonic_time(:millisecond)
        duration = end_time - start_time

        materialized_result = Adbc.Result.materialize(result)
        row_count = get_result_row_count(materialized_result)

        Logger.debug("[SQL DEBUG] Query completed in #{duration}ms, returned #{row_count} rows")
        {:ok, materialized_result}

      error ->
        end_time = System.monotonic_time(:millisecond)
        duration = end_time - start_time

        Logger.error("[SQL DEBUG] Query failed after #{duration}ms: #{inspect(error)}")
        error
    end
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
  Converts ADBC result to rows format for easier data access.
  Returns list of lists where each inner list represents a row.
  """
  def to_rows(%Adbc.Result{data: columns}) do
    case columns do
      [] ->
        []

      [first_col | _] ->
        row_count = length(first_col.data)

        for row_index <- 0..(row_count - 1) do
          Enum.map(columns, fn col ->
            Enum.at(col.data, row_index)
          end)
        end
    end
  end

  # Helper function to get row count from ADBC result for debugging
  defp get_result_row_count(%Adbc.Result{data: columns}) do
    case columns do
      [] -> 0
      [first_col | _] -> length(first_col.data)
    end
  end
end
