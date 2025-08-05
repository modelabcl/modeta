defmodule Modeta.OData.PaginationIntegrationTest do
  use ExUnit.Case, async: true
  alias Modeta.{Cache, Collections}
  alias Modeta.OData.{QueryBuilder, ResponseFormatter}

  @moduletag capture_log: true

  describe "LIMIT + 1 pagination detection" do
    test "correctly detects when more data exists" do
      # Test with large_test table (10,000 rows)
      group_name = "sales_test"
      collection_name = "large_test"

      # Get base query for large_test
      {:ok, base_query} = Collections.get_query(group_name, collection_name)

      # Request first 100 rows with LIMIT + 1 detection
      skip_param = "0"
      top_param = "100"

      # Build query with pagination (should use LIMIT 101)
      final_query =
        QueryBuilder.build_query_with_options(
          base_query,
          group_name,
          collection_name,
          # filter
          nil,
          # expand
          nil,
          # select
          nil,
          # orderby
          nil,
          skip_param,
          top_param
        )

      # Verify the query uses LIMIT 101 (100 + 1 for detection)
      assert String.contains?(final_query, "LIMIT 101 OFFSET 0")

      # Execute the query
      {:ok, result} = Cache.query(final_query)
      rows = Cache.to_rows(result)

      # Should get 101 rows (100 requested + 1 for detection)
      assert length(rows) == 101

      # Format the response using ResponseFormatter
      conn = %{scheme: "https", host: "test.example.com", port: 443}
      context_url = "https://test.example.com/sales_test/$metadata#large_test"

      formatted_rows = ResponseFormatter.format_rows_as_objects(rows, ["id", "description"])

      response =
        ResponseFormatter.build_paginated_response(
          context_url,
          formatted_rows,
          conn,
          group_name,
          collection_name,
          %{},
          skip_param,
          top_param
        )

      # Should return exactly 100 rows in the response
      assert length(response["value"]) == 100

      # Should include @odata.nextLink because we detected more data
      assert Map.has_key?(response, "@odata.nextLink")

      # Verify the next link contains correct pagination parameters
      next_link = response["@odata.nextLink"]
      assert String.contains?(next_link, "$skip=100")
      assert String.contains?(next_link, "$top=100")
    end

    test "correctly detects when no more data exists" do
      # Test with customers table (only 10 rows)
      group_name = "sales_test"
      collection_name = "customers"

      # Get base query for customers
      {:ok, base_query} = Collections.get_query(group_name, collection_name)

      # Request 20 rows (more than available)
      skip_param = "0"
      top_param = "20"

      # Build query with pagination (should use LIMIT 21)
      final_query =
        QueryBuilder.build_query_with_options(
          base_query,
          group_name,
          collection_name,
          # filter
          nil,
          # expand
          nil,
          # select
          nil,
          # orderby
          nil,
          skip_param,
          top_param
        )

      # Verify the query uses LIMIT 21 (20 + 1 for detection)
      assert String.contains?(final_query, "LIMIT 21 OFFSET 0")

      # Execute the query
      {:ok, result} = Cache.query(final_query)
      rows = Cache.to_rows(result)

      # Should get only 10 rows (all available data, less than requested)
      assert length(rows) == 10

      # Format the response using ResponseFormatter
      conn = %{scheme: "https", host: "test.example.com", port: 443}
      context_url = "https://test.example.com/sales_test/$metadata#customers"

      formatted_rows =
        ResponseFormatter.format_rows_as_objects(rows, ["id", "name", "email", "age", "country"])

      response =
        ResponseFormatter.build_paginated_response(
          context_url,
          formatted_rows,
          conn,
          group_name,
          collection_name,
          %{},
          skip_param,
          top_param
        )

      # Should return all 10 available rows
      assert length(response["value"]) == 10

      # Should NOT include @odata.nextLink because we detected no more data
      refute Map.has_key?(response, "@odata.nextLink")
    end

    test "handles last page correctly" do
      # Test requesting the last page of large_test data
      group_name = "sales_test"
      collection_name = "large_test"

      # Get base query for large_test (10,000 rows total)
      {:ok, base_query} = Collections.get_query(group_name, collection_name)

      # Request last 100 rows (skip 9900, get remaining 100)
      skip_param = "9900"
      top_param = "100"

      # Build query with pagination (should use LIMIT 101)
      final_query =
        QueryBuilder.build_query_with_options(
          base_query,
          group_name,
          collection_name,
          # filter
          nil,
          # expand
          nil,
          # select
          nil,
          # orderby
          nil,
          skip_param,
          top_param
        )

      # Verify the query uses LIMIT 101 OFFSET 9900
      assert String.contains?(final_query, "LIMIT 101 OFFSET 9900")

      # Execute the query
      {:ok, result} = Cache.query(final_query)
      rows = Cache.to_rows(result)

      # Should get exactly 100 rows (the last page, no extra row)
      assert length(rows) == 100

      # Format the response using ResponseFormatter
      conn = %{scheme: "https", host: "test.example.com", port: 443}
      context_url = "https://test.example.com/sales_test/$metadata#large_test"

      formatted_rows = ResponseFormatter.format_rows_as_objects(rows, ["id", "description"])

      response =
        ResponseFormatter.build_paginated_response(
          context_url,
          formatted_rows,
          conn,
          group_name,
          collection_name,
          %{},
          skip_param,
          top_param
        )

      # Should return all 100 rows from the last page
      assert length(response["value"]) == 100

      # Should NOT include @odata.nextLink because this is the last page
      refute Map.has_key?(response, "@odata.nextLink")

      # Verify we got the correct rows (IDs 9901 to 10000)
      first_row = List.first(response["value"])
      last_row = List.last(response["value"])

      assert first_row["id"] == 9901
      assert last_row["id"] == 10_000
    end

    test "handles middle page correctly" do
      # Test requesting a middle page that should have more data after it
      group_name = "sales_test"
      collection_name = "large_test"

      # Get base query for large_test (10,000 rows total)
      {:ok, base_query} = Collections.get_query(group_name, collection_name)

      # Request middle page (skip 5000, get 100 rows - should have more after)
      skip_param = "5000"
      top_param = "100"

      # Build query with pagination (should use LIMIT 101)
      final_query =
        QueryBuilder.build_query_with_options(
          base_query,
          group_name,
          collection_name,
          # filter
          nil,
          # expand
          nil,
          # select
          nil,
          # orderby
          nil,
          skip_param,
          top_param
        )

      # Execute the query
      {:ok, result} = Cache.query(final_query)
      rows = Cache.to_rows(result)

      # Should get 101 rows (100 requested + 1 for detection)
      assert length(rows) == 101

      # Format the response using ResponseFormatter
      conn = %{scheme: "https", host: "test.example.com", port: 443}
      context_url = "https://test.example.com/sales_test/$metadata#large_test"

      formatted_rows = ResponseFormatter.format_rows_as_objects(rows, ["id", "description"])

      response =
        ResponseFormatter.build_paginated_response(
          context_url,
          formatted_rows,
          conn,
          group_name,
          collection_name,
          %{},
          skip_param,
          top_param
        )

      # Should return exactly 100 rows in the response
      assert length(response["value"]) == 100

      # Should include @odata.nextLink because we detected more data
      assert Map.has_key?(response, "@odata.nextLink")

      # Verify we got the correct rows (IDs 5001 to 5100)
      first_row = List.first(response["value"])
      last_row = List.last(response["value"])

      assert first_row["id"] == 5001
      assert last_row["id"] == 5100

      # Verify the next link contains correct pagination parameters
      next_link = response["@odata.nextLink"]
      assert String.contains?(next_link, "$skip=5100")
      assert String.contains?(next_link, "$top=100")
    end
  end
end
