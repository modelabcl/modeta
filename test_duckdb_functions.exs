#!/usr/bin/env elixir

Mix.install([{:duckdbex, "~> 0.3"}])

IO.puts("Testing DuckDB system functions...")

case Duckdbex.open(":memory:") do
  {:ok, ddb} ->
    case Duckdbex.connection(ddb) do
      {:ok, conn} ->
        IO.puts("✓ Connection established")

        # Test available system functions
        test_queries = [
          "SELECT * FROM duckdb_functions() WHERE function_name LIKE '%table%' LIMIT 5",
          "SELECT * FROM duckdb_tables() LIMIT 5",
          "SELECT * FROM duckdb_schemas() LIMIT 5"
        ]

        Enum.each(test_queries, fn query ->
          IO.puts("\nTesting: #{query}")

          case Duckdbex.query(conn, query) do
            {:ok, result} ->
              data = Duckdbex.fetch_all(result)
              IO.puts("Result: #{inspect(data)}")

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
