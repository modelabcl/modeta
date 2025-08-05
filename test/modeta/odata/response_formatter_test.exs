defmodule Modeta.OData.ResponseFormatterTest do
  use ExUnit.Case, async: true
  alias Modeta.OData.ResponseFormatter

  @moduletag capture_log: true

  describe "format_rows_as_objects/2" do
    test "formats database rows as JSON objects" do
      rows = [
        ["John", "john@example.com", 25],
        ["Jane", "jane@example.com", 30]
      ]

      column_names = ["name", "email", "age"]

      result = ResponseFormatter.format_rows_as_objects(rows, column_names)

      expected = [
        %{"name" => "John", "email" => "john@example.com", "age" => 25},
        %{"name" => "Jane", "email" => "jane@example.com", "age" => 30}
      ]

      assert result == expected
    end

    test "handles empty rows" do
      rows = []
      column_names = ["name", "email", "age"]

      result = ResponseFormatter.format_rows_as_objects(rows, column_names)

      assert result == []
    end

    test "handles single row" do
      rows = [["Alice", "alice@example.com", 28]]
      column_names = ["name", "email", "age"]

      result = ResponseFormatter.format_rows_as_objects(rows, column_names)

      expected = [%{"name" => "Alice", "email" => "alice@example.com", "age" => 28}]
      assert result == expected
    end

    test "handles different data types" do
      rows = [
        ["Product", 999.99, true, nil],
        ["Service", 0.0, false, "note"]
      ]

      column_names = ["name", "price", "active", "description"]

      result = ResponseFormatter.format_rows_as_objects(rows, column_names)

      expected = [
        %{"name" => "Product", "price" => 999.99, "active" => true, "description" => nil},
        %{"name" => "Service", "price" => 0.0, "active" => false, "description" => "note"}
      ]

      assert result == expected
    end
  end

  describe "format_single_row_as_object/2" do
    test "formats single database row as JSON object" do
      row = ["John", "john@example.com", 25]
      column_names = ["name", "email", "age"]

      result = ResponseFormatter.format_single_row_as_object(row, column_names)

      expected = %{"name" => "John", "email" => "john@example.com", "age" => 25}
      assert result == expected
    end

    test "handles empty values" do
      row = ["", nil, 0]
      column_names = ["name", "email", "age"]

      result = ResponseFormatter.format_single_row_as_object(row, column_names)

      expected = %{"name" => "", "email" => nil, "age" => 0}
      assert result == expected
    end
  end

  describe "build_context_url/3" do
    test "builds basic context URL without select" do
      base_url = "http://example.com/api"
      entity_set = "customers"

      result = ResponseFormatter.build_context_url(base_url, entity_set)

      expected = "http://example.com/api/$metadata#customers"
      assert result == expected
    end

    test "builds context URL with select parameter" do
      base_url = "http://example.com/api"
      entity_set = "customers"
      select_param = "name,email"

      result = ResponseFormatter.build_context_url(base_url, entity_set, select_param)

      expected = "http://example.com/api/$metadata#customers(name,email)"
      assert result == expected
    end

    test "handles select parameter with spaces" do
      base_url = "http://example.com/api"
      entity_set = "products"
      select_param = " name , price , category "

      result = ResponseFormatter.build_context_url(base_url, entity_set, select_param)

      expected = "http://example.com/api/$metadata#products(name,price,category)"
      assert result == expected
    end

    test "ignores empty select columns" do
      base_url = "http://example.com/api"
      entity_set = "orders"
      select_param = "id,,total,"

      result = ResponseFormatter.build_context_url(base_url, entity_set, select_param)

      expected = "http://example.com/api/$metadata#orders(id,total)"
      assert result == expected
    end

    test "returns basic URL when select has no valid columns" do
      base_url = "http://example.com/api"
      entity_set = "items"
      select_param = ",,,"

      result = ResponseFormatter.build_context_url(base_url, entity_set, select_param)

      expected = "http://example.com/api/$metadata#items"
      assert result == expected
    end

    test "handles entity path with $entity" do
      base_url = "http://example.com/api"
      entity_set = "customers/$entity"

      result = ResponseFormatter.build_context_url(base_url, entity_set)

      expected = "http://example.com/api/$metadata#customers/$entity"
      assert result == expected
    end
  end

  describe "get_odata_content_type/1" do
    test "returns minimal metadata by default" do
      result = ResponseFormatter.get_odata_content_type(nil)

      expected =
        "application/json;odata.metadata=minimal;odata.streaming=true;IEEE754Compatible=false"

      assert result == expected
    end

    test "parses full metadata from accept header" do
      accept_header = "application/json;odata.metadata=full"

      result = ResponseFormatter.get_odata_content_type(accept_header)

      expected =
        "application/json;odata.metadata=full;odata.streaming=true;IEEE754Compatible=false"

      assert result == expected
    end

    test "parses none metadata from accept header" do
      accept_header = "application/json;odata.metadata=none"

      result = ResponseFormatter.get_odata_content_type(accept_header)

      expected =
        "application/json;odata.metadata=none;odata.streaming=true;IEEE754Compatible=false"

      assert result == expected
    end

    test "defaults to minimal for unknown metadata type" do
      accept_header = "application/json;odata.metadata=unknown"

      result = ResponseFormatter.get_odata_content_type(accept_header)

      expected =
        "application/json;odata.metadata=minimal;odata.streaming=true;IEEE754Compatible=false"

      assert result == expected
    end

    test "handles complex accept headers" do
      accept_header = "application/json;charset=utf-8;odata.metadata=full;q=0.8"

      result = ResponseFormatter.get_odata_content_type(accept_header)

      expected =
        "application/json;odata.metadata=full;odata.streaming=true;IEEE754Compatible=false"

      assert result == expected
    end
  end

  describe "build_next_link_url/6" do
    test "builds next page URL with updated skip parameter" do
      conn = %{scheme: "https", host: "api.example.com", port: 443}
      group_name = "sales"
      collection_name = "orders"
      params = %{"$filter" => "total gt 100", "$orderby" => "date desc"}
      next_skip = 50
      current_top = 25

      result =
        ResponseFormatter.build_next_link_url(
          conn,
          group_name,
          collection_name,
          params,
          next_skip,
          current_top
        )

      expected =
        "https://api.example.com:443/sales/orders?$filter=total%20gt%20100&$orderby=date%20desc&$skip=50&$top=25"

      assert result == expected
    end

    test "handles parameters with special characters" do
      conn = %{scheme: "http", host: "localhost", port: 4000}
      group_name = "test"
      collection_name = "items"
      params = %{"$filter" => "name eq 'Test & Co'", "$select" => "id,name"}
      next_skip = 10
      current_top = 5

      result =
        ResponseFormatter.build_next_link_url(
          conn,
          group_name,
          collection_name,
          params,
          next_skip,
          current_top
        )

      # URI.encode should handle special characters
      assert String.contains?(result, "http://localhost:4000/test/items")
      assert String.contains?(result, "$skip=10")
      assert String.contains?(result, "$top=5")
      # Check that the filter parameter is properly encoded (spaces become %20)
      assert String.contains?(result, "name%20eq%20'Test%20&%20Co'")
    end

    test "preserves all original parameters" do
      conn = %{scheme: "http", host: "localhost", port: 8080}
      group_name = "data"
      collection_name = "products"

      params = %{
        "$filter" => "price gt 50",
        "$orderby" => "name",
        "$select" => "id,name,price",
        "$expand" => "category"
      }

      next_skip = 100
      current_top = 20

      result =
        ResponseFormatter.build_next_link_url(
          conn,
          group_name,
          collection_name,
          params,
          next_skip,
          current_top
        )

      assert String.contains?(result, "$filter=")
      assert String.contains?(result, "$orderby=")
      assert String.contains?(result, "$select=")
      assert String.contains?(result, "$expand=")
      assert String.contains?(result, "$skip=100")
      assert String.contains?(result, "$top=20")
    end
  end

  describe "build_paginated_response/8" do
    setup do
      conn = %{scheme: "https", host: "api.example.com", port: 443}
      context_url = "https://api.example.com/test/$metadata#customers"

      %{conn: conn, context_url: context_url}
    end

    test "builds basic response without pagination", %{conn: conn, context_url: context_url} do
      rows = [
        %{"id" => 1, "name" => "John"},
        %{"id" => 2, "name" => "Jane"}
      ]

      result =
        ResponseFormatter.build_paginated_response(
          context_url,
          rows,
          conn,
          "test",
          "customers",
          %{},
          nil,
          nil
        )

      expected = %{
        "@odata.context" => context_url,
        "value" => rows
      }

      assert result == expected
    end

    test "includes @odata.nextLink when page is full", %{conn: conn, context_url: context_url} do
      # Create 6 rows (LIMIT + 1 detection: more than requested page size of 5)
      rows = Enum.map(1..6, fn i -> %{"id" => i, "name" => "User #{i}"} end)
      params = %{"$filter" => "active eq true"}

      result =
        ResponseFormatter.build_paginated_response(
          context_url,
          rows,
          conn,
          "test",
          "customers",
          params,
          "0",
          "5"
        )

      # Should return only first 5 rows (since we requested top=5)
      expected_rows = Enum.take(rows, 5)

      assert result["@odata.context"] == context_url
      assert result["value"] == expected_rows
      assert Map.has_key?(result, "@odata.nextLink")

      next_link = result["@odata.nextLink"]
      assert String.contains?(next_link, "$skip=5")
      assert String.contains?(next_link, "$top=5")
    end

    test "no next link when page is not full", %{conn: conn, context_url: context_url} do
      # Create 3 rows (less than the page size)
      rows = Enum.map(1..3, fn i -> %{"id" => i, "name" => "User #{i}"} end)

      result =
        ResponseFormatter.build_paginated_response(
          context_url,
          rows,
          conn,
          "test",
          "customers",
          %{},
          nil,
          "5"
        )

      assert result["@odata.context"] == context_url
      assert result["value"] == rows
      refute Map.has_key?(result, "@odata.nextLink")
    end

    test "handles custom skip and top parameters", %{conn: conn, context_url: context_url} do
      # Create 11 rows (LIMIT + 1 detection: more than requested page size of 10)
      rows = Enum.map(1..11, fn i -> %{"id" => i, "name" => "User #{i}"} end)

      result =
        ResponseFormatter.build_paginated_response(
          context_url,
          rows,
          conn,
          "test",
          "customers",
          %{},
          "20",
          "10"
        )

      # Should return only first 10 rows (since we requested top=10)
      expected_rows = Enum.take(rows, 10)
      assert result["value"] == expected_rows
      assert Map.has_key?(result, "@odata.nextLink")

      next_link = result["@odata.nextLink"]
      assert String.contains?(next_link, "$skip=30")
      assert String.contains?(next_link, "$top=10")
    end

    test "enforces maximum page size limit", %{conn: conn, context_url: context_url} do
      # Request 10000 records (above max of 5000), create 5001 rows (LIMIT + 1 detection)
      rows = Enum.map(1..5001, fn i -> %{"id" => i, "name" => "User #{i}"} end)

      result =
        ResponseFormatter.build_paginated_response(
          context_url,
          rows,
          conn,
          "test",
          "customers",
          %{},
          nil,
          "10000"
        )

      # Should return first 5000 rows (max page size limit)
      expected_rows = Enum.take(rows, 5000)
      assert result["value"] == expected_rows
      assert Map.has_key?(result, "@odata.nextLink")

      next_link = result["@odata.nextLink"]
      # Should be limited to max page size of 5000
      assert String.contains?(next_link, "$top=5000")
    end

    test "handles invalid skip values", %{conn: conn, context_url: context_url} do
      rows = [%{"id" => 1, "name" => "Test"}]

      result1 =
        ResponseFormatter.build_paginated_response(
          context_url,
          rows,
          conn,
          "test",
          "customers",
          %{},
          "invalid",
          nil
        )

      result2 =
        ResponseFormatter.build_paginated_response(
          context_url,
          rows,
          conn,
          "test",
          "customers",
          %{},
          "-10",
          nil
        )

      # Both should treat invalid skip as 0
      refute Map.has_key?(result1, "@odata.nextLink")
      refute Map.has_key?(result2, "@odata.nextLink")
    end

    test "handles invalid top values", %{conn: conn, context_url: context_url} do
      # Create 1001 rows (LIMIT + 1 detection: more than default page size of 1000)
      rows = Enum.map(1..1001, fn i -> %{"id" => i, "name" => "User #{i}"} end)

      result1 =
        ResponseFormatter.build_paginated_response(
          context_url,
          rows,
          conn,
          "test",
          "customers",
          %{},
          nil,
          "invalid"
        )

      result2 =
        ResponseFormatter.build_paginated_response(
          context_url,
          rows,
          conn,
          "test",
          "customers",
          %{},
          nil,
          "0"
        )

      # Both should use default page size (1000) and include next link
      assert Map.has_key?(result1, "@odata.nextLink")
      assert Map.has_key?(result2, "@odata.nextLink")

      assert String.contains?(result1["@odata.nextLink"], "$top=1000")
      assert String.contains?(result2["@odata.nextLink"], "$top=1000")
    end

    test "handles integer parameters", %{conn: conn, context_url: context_url} do
      # Create 16 rows (LIMIT + 1 detection: more than requested page size of 15)
      rows = Enum.map(1..16, fn i -> %{"id" => i, "name" => "User #{i}"} end)

      result =
        ResponseFormatter.build_paginated_response(
          context_url,
          rows,
          conn,
          "test",
          "customers",
          %{},
          50,
          15
        )

      # Should return first 15 rows (since we requested top=15)
      expected_rows = Enum.take(rows, 15)
      assert result["value"] == expected_rows
      assert Map.has_key?(result, "@odata.nextLink")

      next_link = result["@odata.nextLink"]
      assert String.contains?(next_link, "$skip=65")
      assert String.contains?(next_link, "$top=15")
    end
  end

  describe "format_rows_with_expansion/5" do
    test "returns basic formatting when collection not found" do
      rows = [["John", "john@example.com"], ["Jane", "jane@example.com"]]
      column_names = ["name", "email"]

      result =
        ResponseFormatter.format_rows_with_expansion(
          rows,
          column_names,
          "nonexistent",
          "users",
          "Profile"
        )

      expected = [
        %{"name" => "John", "email" => "john@example.com"},
        %{"name" => "Jane", "email" => "jane@example.com"}
      ]

      assert result == expected
    end

    # Note: Full expansion testing would require mock Collections.get_collection/2
    # which is better tested in integration tests with the full OData system
  end
end
