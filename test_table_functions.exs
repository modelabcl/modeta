#!/usr/bin/env elixir

Mix.install([{:duckdbex, "~> 0.3"}])

case Duckdbex.open(":memory:") do
  {:ok, ddb} ->
    case Duckdbex.connection(ddb) do
      {:ok, conn} ->
        # First create a test table
        {:ok, _} = Duckdbex.query(conn, "CREATE SCHEMA test_schema")
        {:ok, _} = Duckdbex.query(conn, "CREATE TABLE test_schema.test_table (id INTEGER)")

        # Test different ways to list tables
        test_queries = [
          "SHOW TABLES",
          "SELECT * FROM information_schema.tables",
          "SELECT table_name, schema_name FROM duckdb_schemas() s, duckdb_tables() t WHERE s.schema_name = t.schema_name",
          "PRAGMA show_tables",
          "SELECT * FROM duckdb_functions() WHERE function_name LIKE '%tables%'"
        ]

        Enum.each(test_queries, fn query ->
          IO.puts("\nTesting: #{query}")

          case Duckdbex.query(conn, query) do
            {:ok, result} ->
              data = Duckdbex.fetch_all(result)
              IO.puts("Result: #{inspect(Enum.take(data, 3))}")

            {:error, reason} ->
              IO.puts("Error: #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        IO.puts("Connection failed: #{inspect(reason)}")
    end

  {:error, reason} ->
    IO.puts("Database open failed: #{inspect(reason)}")
end
