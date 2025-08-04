#!/usr/bin/env elixir

Mix.install([{:duckdbex, "~> 0.3"}])

IO.puts("Testing DuckDBex API...")

case Duckdbex.open(":memory:") do
  {:ok, ddb} ->
    IO.puts("✓ Database opened successfully")

    case Duckdbex.connection(ddb) do
      {:ok, conn} ->
        IO.puts("✓ Connection created successfully")

        # Test query that should return empty results
        case Duckdbex.query(
               conn,
               "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'nonexistent'"
             ) do
          {:ok, result} ->
            IO.puts("✓ Query executed successfully")
            IO.puts("Query result: #{inspect(result)}")

            case Duckdbex.fetch_all(result) do
              {:ok, data} ->
                IO.puts("✓ Fetch all successful")
                IO.puts("Data: #{inspect(data)}")

              fetch_result ->
                IO.puts("Fetch result: #{inspect(fetch_result)}")
            end

          {:error, reason} ->
            IO.puts("✗ Query failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        IO.puts("✗ Connection failed: #{inspect(reason)}")
    end

  {:error, reason} ->
    IO.puts("✗ Database open failed: #{inspect(reason)}")
end
