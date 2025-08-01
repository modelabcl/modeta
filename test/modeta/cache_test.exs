defmodule Modeta.CacheTest do
  use ExUnit.Case, async: false
  alias Modeta.Cache

  @fixtures_path Path.join([__DIR__, "..", "fixtures"])
  @customers_csv Path.join(@fixtures_path, "customers.csv")

  describe "Cache module" do
    test "can load CSV file and query data" do
      # Load the CSV file into DuckDB
      assert {:ok, table_name} = Cache.load_csv(@customers_csv, "customers")
      assert table_name == "customers"

      # Query all customers - check table structure
      assert {:ok, %Adbc.Result{data: columns}} = Cache.select("customers")
      # Should have 7 columns
      assert length(columns) == 7

      # Verify column names
      column_names = Enum.map(columns, & &1.name)
      assert "id" in column_names
      assert "name" in column_names
      assert "email" in column_names
      assert "country" in column_names

      # Query specific columns
      assert {:ok, %Adbc.Result{data: columns}} = Cache.select("customers", "name, email")
      assert length(columns) == 2
      [name_col, email_col] = columns
      assert name_col.name == "name"
      assert email_col.name == "email"

      # Query with WHERE clause - just check it doesn't error
      assert {:ok, %Adbc.Result{data: filtered_columns}} =
               Cache.select("customers", "*", "age > 40")

      # Same columns
      assert length(filtered_columns) == 7
    end

    test "can describe table structure" do
      # Load the CSV file
      {:ok, _} = Cache.load_csv(@customers_csv, "customers_desc")

      # Describe the table
      assert {:ok, %Adbc.Result{data: desc_columns}} = Cache.describe_table("customers_desc")
      assert length(desc_columns) > 0

      # Should have columns for name, type, etc.
      [first_column | _] = desc_columns
      assert first_column.name == "column_name"
    end

    test "can execute custom SQL queries" do
      # Load the CSV file
      {:ok, _} = Cache.load_csv(@customers_csv, "customers_custom")

      # Execute a custom aggregation query
      sql =
        "SELECT country, COUNT(*) as customer_count FROM customers_custom GROUP BY country ORDER BY customer_count DESC"

      assert {:ok, %Adbc.Result{data: result_columns}} = Cache.query(sql)
      assert length(result_columns) == 2

      # Should have country and count columns
      [country_col, count_col] = result_columns
      assert country_col.name == "country"
      assert count_col.name == "customer_count"
    end

    test "handles file loading errors gracefully" do
      # Try to load a non-existent file
      non_existent_path = Path.join(@fixtures_path, "non_existent.csv")
      assert {:error, _} = Cache.load_csv(non_existent_path)
    end

    test "handles invalid SQL gracefully" do
      # Try to execute invalid SQL
      assert {:error, _} = Cache.query("INVALID SQL STATEMENT")
    end

    test "can get specific customer name by ID" do
      # Load the CSV file
      {:ok, _} = Cache.load_csv(@customers_csv, "customers_name_test")

      # Query for customer ID 1's name (should be John Doe)
      assert {:ok, result} = Cache.select("customers_name_test", "name", "id = 1")

      # With materialized data, we should be able to extract the actual value
      # The result is still an Adbc.Result but with actual data instead of references
      assert %Adbc.Result{data: columns} = result
      assert length(columns) == 1

      [name_column] = columns
      assert name_column.name == "name"
      assert name_column.data == ["John Doe"]
    end

    test "can convert ADBC result to rows format" do
      # Load the CSV file
      {:ok, _} = Cache.load_csv(@customers_csv, "customers_rows_test")

      # Query multiple customers
      assert {:ok, result} = Cache.select("customers_rows_test", "name, country", "id <= 3")

      # Convert to rows format
      rows = Cache.to_rows(result)

      # Should have 3 rows
      assert length(rows) == 3

      # First row should be John Doe from USA
      [first_row | _] = rows
      assert first_row == ["John Doe", "USA"]

      # Check that all rows have 2 columns
      Enum.each(rows, fn row ->
        assert length(row) == 2
      end)
    end
  end
end
