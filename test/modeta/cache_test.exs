defmodule Modeta.CacheTest do
  use ExUnit.Case, async: false
  alias Modeta.Cache

  @fixtures_path Path.join([__DIR__, "..", "fixtures"])
  @customers_csv Path.join(@fixtures_path, "customers.csv")

  describe "Cache module with DuckDBex" do
    test "can load CSV file and query data" do
      # Load the CSV file into DuckDB
      assert {:ok, table_name} = Cache.load_csv(@customers_csv, "customers")
      assert table_name == "customers"

      # Query all customers - check structure with DuckDBex format
      assert {:ok, %{data: rows}} = Cache.select("customers")
      # Should have at least some rows
      assert length(rows) > 0

      # Query specific columns
      assert {:ok, %{data: name_email_rows}} = Cache.select("customers", "name, email")
      assert length(name_email_rows) > 0

      # Each row should have 2 columns (name, email)
      [first_row | _] = name_email_rows
      assert length(first_row) == 2

      # Query with WHERE clause - just check it doesn't error
      assert {:ok, %{data: filtered_rows}} = Cache.select("customers", "*", "age > 30")
      assert is_list(filtered_rows)
    end

    test "can describe table structure" do
      # Load the CSV file
      {:ok, _} = Cache.load_csv(@customers_csv, "customers_desc")

      # Describe the table
      assert {:ok, %{data: desc_rows}} = Cache.describe_table("customers_desc")
      assert length(desc_rows) > 0

      # Each describe row should have at least column name and type
      [first_row | _] = desc_rows
      assert length(first_row) >= 2
    end

    test "can execute custom SQL queries" do
      # Load the CSV file
      {:ok, _} = Cache.load_csv(@customers_csv, "customers_custom")

      # Execute a custom aggregation query
      sql = "SELECT COUNT(*) as customer_count FROM customers_custom"

      assert {:ok, %{data: result_rows}} = Cache.query(sql)
      assert length(result_rows) == 1

      # Should return count
      [count_row] = result_rows
      [count_value] = count_row
      assert is_integer(count_value) and count_value > 0
    end

    @tag capture_log: true
    test "handles file loading errors gracefully" do
      # Try to load a non-existent file
      non_existent_path = Path.join(@fixtures_path, "non_existent.csv")
      assert {:error, _} = Cache.load_csv(non_existent_path)
    end

    @tag capture_log: true
    test "handles invalid SQL gracefully" do
      # Try to execute invalid SQL
      assert {:error, _} = Cache.query("INVALID SQL STATEMENT")
    end

    test "can convert result to rows format" do
      # Load the CSV file
      {:ok, _} = Cache.load_csv(@customers_csv, "customers_rows_test")

      # Query multiple customers
      assert {:ok, result} = Cache.select("customers_rows_test", "name, country", "id <= 3")

      # Convert to rows format (DuckDBex already returns rows)
      rows = Cache.to_rows(result)

      # Should have rows
      assert length(rows) > 0

      # Check that all rows have 2 columns
      Enum.each(rows, fn row ->
        assert length(row) == 2
        # name should be string
        assert is_binary(hd(row))
      end)
    end

    test "can get column names" do
      # Load the CSV file  
      {:ok, _} = Cache.load_csv(@customers_csv, "customers_cols_test")

      # Get column names
      column_names = Cache.get_column_names("customers_cols_test")

      # Should have expected columns
      assert "id" in column_names
      assert "name" in column_names
      assert "email" in column_names
    end
  end
end
