defmodule Modeta.OData.PaginationHandlerTest do
  use ExUnit.Case, async: true
  alias Modeta.OData.PaginationHandler

  @moduletag capture_log: true

  describe "should_include_count?/1" do
    test "returns true for string 'true'" do
      assert PaginationHandler.should_include_count?("true") == true
    end

    test "returns true for boolean true" do
      assert PaginationHandler.should_include_count?(true) == true
    end

    test "returns false for string 'false'" do
      assert PaginationHandler.should_include_count?("false") == false
    end

    test "returns false for boolean false" do
      assert PaginationHandler.should_include_count?(false) == false
    end

    test "returns false for nil" do
      assert PaginationHandler.should_include_count?(nil) == false
    end

    test "returns false for empty string" do
      assert PaginationHandler.should_include_count?("") == false
    end

    test "returns false for invalid values" do
      assert PaginationHandler.should_include_count?("maybe") == false
      assert PaginationHandler.should_include_count?("1") == false
      assert PaginationHandler.should_include_count?(1) == false
      assert PaginationHandler.should_include_count?([]) == false
      assert PaginationHandler.should_include_count?(%{}) == false
    end

    test "handles case variations" do
      # OData is case sensitive
      assert PaginationHandler.should_include_count?("TRUE") == false
      assert PaginationHandler.should_include_count?("True") == false
      assert PaginationHandler.should_include_count?("FALSE") == false
      assert PaginationHandler.should_include_count?("False") == false
    end
  end

  describe "build_count_query/2" do
    test "builds basic count query without filter" do
      base_query = "SELECT * FROM customers"
      result = PaginationHandler.build_count_query(base_query, nil)

      expected = "SELECT COUNT(*) as total_count FROM (SELECT * FROM customers) AS count_data"
      assert result == expected
    end

    test "builds count query with filter" do
      base_query = "SELECT * FROM customers"
      filter_param = "age gt 21"

      # Mock the filter application (this would be handled by ODataFilter module)
      _filtered_query = "SELECT * FROM customers WHERE age > 21"

      # We need to mock Modeta.ODataFilter.apply_filter_to_query
      # For testing purposes, we'll test the structure
      result = PaginationHandler.build_count_query(base_query, filter_param)

      assert String.contains?(result, "SELECT COUNT(*) as total_count")
      assert String.contains?(result, "AS count_data")
    end

    test "handles complex base queries" do
      base_query =
        "SELECT c.*, p.name as product_name FROM customers c LEFT JOIN products p ON c.product_id = p.id"

      result = PaginationHandler.build_count_query(base_query, nil)

      assert String.starts_with?(result, "SELECT COUNT(*) as total_count FROM (")
      assert String.ends_with?(result, ") AS count_data")
      assert String.contains?(result, base_query)
    end

    test "handles empty filter parameter" do
      base_query = "SELECT * FROM orders"
      result = PaginationHandler.build_count_query(base_query, "")

      # Empty string filter should be treated as filtered query
      assert String.contains?(result, "SELECT COUNT(*) as total_count")
    end
  end

  describe "validate_count_param/1" do
    test "validates string 'true'" do
      assert PaginationHandler.validate_count_param("true") == {:ok, true}
    end

    test "validates string 'false'" do
      assert PaginationHandler.validate_count_param("false") == {:ok, false}
    end

    test "validates boolean true" do
      assert PaginationHandler.validate_count_param(true) == {:ok, true}
    end

    test "validates boolean false" do
      assert PaginationHandler.validate_count_param(false) == {:ok, false}
    end

    test "validates nil as false" do
      assert PaginationHandler.validate_count_param(nil) == {:ok, false}
    end

    test "returns error for invalid values" do
      assert PaginationHandler.validate_count_param("invalid") ==
               {:error, "Invalid $count value. Expected 'true' or 'false'"}

      assert PaginationHandler.validate_count_param("1") ==
               {:error, "Invalid $count value. Expected 'true' or 'false'"}

      assert PaginationHandler.validate_count_param(1) ==
               {:error, "Invalid $count value. Expected 'true' or 'false'"}

      assert PaginationHandler.validate_count_param([]) ==
               {:error, "Invalid $count value. Expected 'true' or 'false'"}
    end

    test "handles case sensitivity" do
      assert PaginationHandler.validate_count_param("TRUE") ==
               {:error, "Invalid $count value. Expected 'true' or 'false'"}

      assert PaginationHandler.validate_count_param("True") ==
               {:error, "Invalid $count value. Expected 'true' or 'false'"}
    end
  end

  # Note: get_total_count/2 and execute_count_query/1 tests would require
  # mocking Modeta.Cache and setting up test database scenarios.
  # These are better tested through integration tests with the full system.

  describe "integration scenarios" do
    test "count parameter validation integrates with should_include_count" do
      # Test the typical workflow
      count_param = "true"

      # Validate parameter
      {:ok, validated} = PaginationHandler.validate_count_param(count_param)
      assert validated == true

      # Check if count should be included
      should_include = PaginationHandler.should_include_count?(count_param)
      assert should_include == true

      # Both should be consistent
      assert validated == should_include
    end

    test "handles parameter workflow for false values" do
      count_param = "false"

      {:ok, validated} = PaginationHandler.validate_count_param(count_param)
      assert validated == false

      should_include = PaginationHandler.should_include_count?(count_param)
      assert should_include == false

      assert validated == should_include
    end

    test "handles parameter workflow for nil values" do
      count_param = nil

      {:ok, validated} = PaginationHandler.validate_count_param(count_param)
      assert validated == false

      should_include = PaginationHandler.should_include_count?(count_param)
      assert should_include == false

      assert validated == should_include
    end

    test "validation catches errors that should_include_count would miss" do
      invalid_param = "maybe"

      # Validation should catch the error
      assert {:error, _} = PaginationHandler.validate_count_param(invalid_param)

      # should_include_count would default to false
      assert PaginationHandler.should_include_count?(invalid_param) == false
    end
  end
end
