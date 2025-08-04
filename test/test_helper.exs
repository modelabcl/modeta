# Clean up DuckDB files before running tests
test_db_path = Application.get_env(:modeta, :duckdb_path, "data/modeta_test.duckdb")
expanded_path = Path.expand(test_db_path)

if File.exists?(expanded_path) do
  File.rm!(expanded_path)
  IO.puts("Cleaned up existing test database: #{expanded_path}")
end

# Also clean up any other test database files that might exist
data_dir = Path.dirname(expanded_path)

if File.exists?(data_dir) do
  Path.wildcard(Path.join(data_dir, "*test*.duckdb*"))
  |> Enum.each(fn file ->
    File.rm!(file)
    IO.puts("Cleaned up test database file: #{file}")
  end)
end

ExUnit.start()
