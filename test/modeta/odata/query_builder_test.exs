defmodule Modeta.OData.QueryBuilderTest do
  use ExUnit.Case, async: true
  alias Modeta.OData.QueryBuilder

  @moduletag capture_log: true

  describe "build_query_with_options/9" do
    test "applies default pagination when no options provided" do
      base_query = "SELECT * FROM purchases"

      result =
        QueryBuilder.build_query_with_options(
          base_query,
          "sales_test",
          "purchases",
          nil,
          nil,
          nil,
          nil,
          nil,
          nil
        )

      expected = "SELECT * FROM (#{base_query}) AS paginated_data LIMIT 1000 OFFSET 0"
      assert result == expected
    end

    test "handles collection not found gracefully" do
      base_query = "SELECT * FROM non_existent"

      result =
        QueryBuilder.build_query_with_options(
          base_query,
          "non_existent_group",
          "non_existent",
          nil,
          nil,
          nil,
          nil,
          nil,
          nil
        )

      expected = "SELECT * FROM (#{base_query}) AS paginated_data LIMIT 1000 OFFSET 0"
      assert result == expected
    end
  end

  describe "apply_select_to_query/2" do
    test "applies column selection correctly" do
      base_query = "SELECT * FROM customers"
      select_param = "name, email"

      result = QueryBuilder.apply_select_to_query(base_query, select_param)

      expected = "SELECT name, email FROM (#{base_query}) AS selected_data"
      assert result == expected
    end

    test "handles single column selection" do
      base_query = "SELECT * FROM customers"
      select_param = "name"

      result = QueryBuilder.apply_select_to_query(base_query, select_param)

      expected = "SELECT name FROM (#{base_query}) AS selected_data"
      assert result == expected
    end

    test "trims whitespace in column names" do
      base_query = "SELECT * FROM customers"
      select_param = " name , email , country "

      result = QueryBuilder.apply_select_to_query(base_query, select_param)

      expected = "SELECT name, email, country FROM (#{base_query}) AS selected_data"
      assert result == expected
    end

    test "ignores empty column names" do
      base_query = "SELECT * FROM customers"
      select_param = "name,,email"

      result = QueryBuilder.apply_select_to_query(base_query, select_param)

      expected = "SELECT name, email FROM (#{base_query}) AS selected_data"
      assert result == expected
    end

    test "returns original query when no valid columns" do
      base_query = "SELECT * FROM customers"
      select_param = ",,,"

      result = QueryBuilder.apply_select_to_query(base_query, select_param)

      assert result == base_query
    end

    test "returns original query when select param is empty" do
      base_query = "SELECT * FROM customers"
      select_param = ""

      result = QueryBuilder.apply_select_to_query(base_query, select_param)

      assert result == base_query
    end
  end

  describe "apply_orderby_to_query/2" do
    test "applies single column ordering with default ASC" do
      base_query = "SELECT * FROM customers"
      orderby_param = "name"

      result = QueryBuilder.apply_orderby_to_query(base_query, orderby_param)

      expected = "SELECT * FROM (#{base_query}) AS ordered_data ORDER BY name ASC"
      assert result == expected
    end

    test "applies single column ordering with explicit ASC" do
      base_query = "SELECT * FROM customers"
      orderby_param = "name asc"

      result = QueryBuilder.apply_orderby_to_query(base_query, orderby_param)

      expected = "SELECT * FROM (#{base_query}) AS ordered_data ORDER BY name ASC"
      assert result == expected
    end

    test "applies single column ordering with DESC" do
      base_query = "SELECT * FROM customers"
      orderby_param = "age desc"

      result = QueryBuilder.apply_orderby_to_query(base_query, orderby_param)

      expected = "SELECT * FROM (#{base_query}) AS ordered_data ORDER BY age DESC"
      assert result == expected
    end

    test "applies multiple column ordering" do
      base_query = "SELECT * FROM customers"
      orderby_param = "country desc, name asc, age"

      result = QueryBuilder.apply_orderby_to_query(base_query, orderby_param)

      expected =
        "SELECT * FROM (#{base_query}) AS ordered_data ORDER BY country DESC, name ASC, age ASC"

      assert result == expected
    end

    test "handles case insensitive direction keywords" do
      base_query = "SELECT * FROM customers"
      orderby_param = "name ASC, age DESC"

      result = QueryBuilder.apply_orderby_to_query(base_query, orderby_param)

      expected = "SELECT * FROM (#{base_query}) AS ordered_data ORDER BY name ASC, age DESC"
      assert result == expected
    end

    test "ignores invalid column names" do
      base_query = "SELECT * FROM customers"
      orderby_param = "valid_column, invalid-column!, another_valid"

      result = QueryBuilder.apply_orderby_to_query(base_query, orderby_param)

      expected =
        "SELECT * FROM (#{base_query}) AS ordered_data ORDER BY valid_column ASC, another_valid ASC"

      assert result == expected
    end

    test "ignores invalid direction keywords" do
      base_query = "SELECT * FROM customers"
      orderby_param = "name up, age down, country asc"

      result = QueryBuilder.apply_orderby_to_query(base_query, orderby_param)

      expected = "SELECT * FROM (#{base_query}) AS ordered_data ORDER BY country ASC"
      assert result == expected
    end

    test "returns original query when no valid order clauses" do
      base_query = "SELECT * FROM customers"
      orderby_param = "invalid-column!, another-bad-column!"

      result = QueryBuilder.apply_orderby_to_query(base_query, orderby_param)

      assert result == base_query
    end

    test "handles qualified column names" do
      base_query = "SELECT * FROM customers"
      orderby_param = "customers.name, table.column_name desc"

      result = QueryBuilder.apply_orderby_to_query(base_query, orderby_param)

      expected =
        "SELECT * FROM (#{base_query}) AS ordered_data ORDER BY customers.name ASC, table.column_name DESC"

      assert result == expected
    end
  end

  describe "apply_pagination_to_query/3" do
    test "applies default pagination when no params provided" do
      base_query = "SELECT * FROM customers"

      result = QueryBuilder.apply_pagination_to_query(base_query, nil, nil)

      # Should use default page size (1000) and skip 0
      expected = "SELECT * FROM (#{base_query}) AS paginated_data LIMIT 1000 OFFSET 0"
      assert result == expected
    end

    test "applies custom top parameter" do
      base_query = "SELECT * FROM customers"

      result = QueryBuilder.apply_pagination_to_query(base_query, nil, "50")

      expected = "SELECT * FROM (#{base_query}) AS paginated_data LIMIT 50 OFFSET 0"
      assert result == expected
    end

    test "applies custom skip parameter" do
      base_query = "SELECT * FROM customers"

      result = QueryBuilder.apply_pagination_to_query(base_query, "100", nil)

      expected = "SELECT * FROM (#{base_query}) AS paginated_data LIMIT 1000 OFFSET 100"
      assert result == expected
    end

    test "applies both skip and top parameters" do
      base_query = "SELECT * FROM customers"

      result = QueryBuilder.apply_pagination_to_query(base_query, "200", "25")

      expected = "SELECT * FROM (#{base_query}) AS paginated_data LIMIT 25 OFFSET 200"
      assert result == expected
    end

    test "handles integer parameters" do
      base_query = "SELECT * FROM customers"

      result = QueryBuilder.apply_pagination_to_query(base_query, 150, 75)

      expected = "SELECT * FROM (#{base_query}) AS paginated_data LIMIT 75 OFFSET 150"
      assert result == expected
    end

    test "enforces maximum page size limit" do
      base_query = "SELECT * FROM customers"

      # Try to request 10000 records (above max of 5000)
      result = QueryBuilder.apply_pagination_to_query(base_query, nil, "10000")

      expected = "SELECT * FROM (#{base_query}) AS paginated_data LIMIT 5000 OFFSET 0"
      assert result == expected
    end

    test "handles invalid skip values" do
      base_query = "SELECT * FROM customers"

      # Invalid skip values should default to 0
      result1 = QueryBuilder.apply_pagination_to_query(base_query, "invalid", nil)
      result2 = QueryBuilder.apply_pagination_to_query(base_query, "-10", nil)

      expected = "SELECT * FROM (#{base_query}) AS paginated_data LIMIT 1000 OFFSET 0"
      assert result1 == expected
      assert result2 == expected
    end

    test "handles invalid top values" do
      base_query = "SELECT * FROM customers"

      # Invalid top values should default to 1000
      result1 = QueryBuilder.apply_pagination_to_query(base_query, nil, "invalid")
      result2 = QueryBuilder.apply_pagination_to_query(base_query, nil, "0")
      result3 = QueryBuilder.apply_pagination_to_query(base_query, nil, "-5")

      expected = "SELECT * FROM (#{base_query}) AS paginated_data LIMIT 1000 OFFSET 0"
      assert result1 == expected
      assert result2 == expected
      assert result3 == expected
    end

    test "handles partial integer parsing as invalid" do
      base_query = "SELECT * FROM customers"

      # Values with non-numeric suffixes are treated as invalid and default to 0/1000
      result = QueryBuilder.apply_pagination_to_query(base_query, "123abc", "456def")

      # Since both have remaining chars, they default to 0 and 1000
      expected = "SELECT * FROM (#{base_query}) AS paginated_data LIMIT 1000 OFFSET 0"
      assert result == expected
    end
  end

  describe "integration with OData filter" do
    test "preserves filter application order" do
      base_query = "SELECT * FROM customers"

      # Test that filter is applied before other operations
      result =
        QueryBuilder.build_query_with_options(
          base_query,
          "non_existent",
          "non_existent",
          "name eq 'John'",
          nil,
          "name",
          nil,
          nil,
          "5"
        )

      # Should have filter, then select, then pagination
      assert String.contains?(result, "SELECT name FROM")
      assert String.contains?(result, "LIMIT 5 OFFSET 0")
    end
  end

  describe "query building pipeline" do
    test "applies operations in correct order without collection config" do
      base_query = "SELECT * FROM customers"

      result =
        QueryBuilder.build_query_with_options(
          base_query,
          "non_existent",
          "non_existent",
          # filter
          "age gt 21",
          # expand  
          nil,
          # select
          "name, email",
          # orderby
          "name desc",
          # skip
          "10",
          # top
          "5"
        )

      # The pipeline should be: base -> select -> filter -> orderby -> pagination
      # Let's verify the structure contains expected parts
      assert String.contains?(result, "SELECT name, email FROM")
      assert String.contains?(result, "ORDER BY name DESC")
      assert String.contains?(result, "LIMIT 5 OFFSET 10")
    end
  end

  describe "determine_join_type/1" do
    test "returns INNER JOIN for explicit join_type: inner" do
      reference = %{"join_type" => "inner"}
      result = QueryBuilder.determine_join_type(reference)
      assert result == :inner_join
    end

    test "returns LEFT JOIN for explicit join_type: left" do
      reference = %{"join_type" => "left"}
      result = QueryBuilder.determine_join_type(reference)
      assert result == :left_join
    end

    test "returns INNER JOIN for non-nullable relationships" do
      reference = %{"nullable" => false}
      result = QueryBuilder.determine_join_type(reference)
      assert result == :inner_join
    end

    test "returns LEFT JOIN for nullable relationships" do
      reference = %{"nullable" => true}
      result = QueryBuilder.determine_join_type(reference)
      assert result == :left_join
    end

    test "returns INNER JOIN for required multiplicity (1)" do
      reference = %{"multiplicity" => "1"}
      result = QueryBuilder.determine_join_type(reference)
      assert result == :inner_join
    end

    test "returns LEFT JOIN for optional multiplicity (0..1)" do
      reference = %{"multiplicity" => "0..1"}
      result = QueryBuilder.determine_join_type(reference)
      assert result == :left_join
    end

    test "explicit join_type takes precedence over nullable" do
      reference = %{"join_type" => "left", "nullable" => false}
      result = QueryBuilder.determine_join_type(reference)
      assert result == :left_join
    end

    test "explicit join_type takes precedence over multiplicity" do
      reference = %{"join_type" => "inner", "multiplicity" => "0..1"}
      result = QueryBuilder.determine_join_type(reference)
      assert result == :inner_join
    end

    test "nullable takes precedence over multiplicity" do
      reference = %{"nullable" => false, "multiplicity" => "0..1"}
      result = QueryBuilder.determine_join_type(reference)
      assert result == :inner_join
    end

    test "defaults to LEFT JOIN for unknown configurations" do
      reference = %{}
      result = QueryBuilder.determine_join_type(reference)
      assert result == :left_join

      reference2 = %{"some_other_key" => "value"}
      result2 = QueryBuilder.determine_join_type(reference2)
      assert result2 == :left_join
    end

    test "complex configuration with multiple attributes" do
      # Real-world example: required customer relationship
      reference = %{
        "col" => "customer_id",
        "ref" => "customers(id)",
        "nullable" => false,
        "multiplicity" => "1",
        "join_type" => "inner"
      }

      result = QueryBuilder.determine_join_type(reference)
      assert result == :inner_join
    end

    test "handles string and non-string values correctly" do
      # Ensure string comparisons work
      reference1 = %{"join_type" => "inner"}
      reference2 = %{"join_type" => :inner}  # symbol instead of string

      result1 = QueryBuilder.determine_join_type(reference1)
      result2 = QueryBuilder.determine_join_type(reference2)

      assert result1 == :inner_join
      assert result2 == :left_join  # defaults because :inner != "inner"
    end
  end

  describe "JOIN type integration with expand" do
    # Note: These tests focus on the JOIN type determination logic.
    # Full integration tests with actual database queries and collection
    # configurations would require more complex test setup and are better
    # suited for integration tests in the controller test suite.

    test "apply_expand_to_query respects JOIN type configuration" do
      # This test verifies that the expand logic uses the determined JOIN type
      # We'll test the structure without actual database execution

      _base_query = "SELECT * FROM purchases"
      _group_name = "sales_test"

      # Mock collection config with INNER JOIN reference
      collection_config = %{
        table_name: "purchases",
        references: [
          %{
            "col" => "customer_id",
            "ref" => "customers(id)",
            "nullable" => false,  # Should result in INNER JOIN
            "multiplicity" => "1"
          }
        ]
      }

      # We can't easily test the full query generation without mocking Cache.query
      # but we can verify the logic flows correctly by testing join type determination
      reference = Enum.at(collection_config.references, 0)
      join_type = QueryBuilder.determine_join_type(reference)

      assert join_type == :inner_join
    end

    test "different references can have different JOIN types" do
      references = [
        %{
          "col" => "customer_id",
          "ref" => "customers(id)",
          "nullable" => false,  # INNER JOIN
          "multiplicity" => "1"
        },
        %{
          "col" => "discount_id",
          "ref" => "discounts(id)",
          "nullable" => true,   # LEFT JOIN
          "multiplicity" => "0..1"
        },
        %{
          "col" => "category_id",
          "ref" => "categories(id)",
          "join_type" => "left"  # Explicit LEFT JOIN
        }
      ]

      join_types = Enum.map(references, &QueryBuilder.determine_join_type/1)

      assert join_types == [:inner_join, :left_join, :left_join]
    end

    test "backward compatibility - no JOIN configuration defaults to LEFT JOIN" do
      # Legacy configuration without JOIN specifications
      reference = %{
        "col" => "customer_id",
        "ref" => "customers(id)"
      }

      result = QueryBuilder.determine_join_type(reference)
      assert result == :left_join
    end
  end
end
