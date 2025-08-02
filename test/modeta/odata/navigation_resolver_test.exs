defmodule Modeta.OData.NavigationResolverTest do
  use ExUnit.Case, async: true
  alias Modeta.OData.NavigationResolver

  @moduletag capture_log: true

  describe "parse_collection_and_key/1" do
    test "parses valid collection and key format" do
      result = NavigationResolver.parse_collection_and_key("customers(1)")
      assert result == {:ok, "customers", "1"}
    end

    test "parses collection with string key" do
      result = NavigationResolver.parse_collection_and_key("orders(abc-123)")
      assert result == {:ok, "orders", "abc-123"}
    end

    test "parses collection with UUID key" do
      result =
        NavigationResolver.parse_collection_and_key(
          "products(550e8400-e29b-41d4-a716-446655440000)"
        )

      assert result == {:ok, "products", "550e8400-e29b-41d4-a716-446655440000"}
    end

    test "parses collection with underscore in name" do
      result = NavigationResolver.parse_collection_and_key("sales_orders(42)")
      assert result == {:ok, "sales_orders", "42"}
    end

    test "handles collection names starting with letter" do
      result = NavigationResolver.parse_collection_and_key("a1_test(999)")
      assert result == {:ok, "a1_test", "999"}
    end

    test "returns error for invalid format without parentheses" do
      result = NavigationResolver.parse_collection_and_key("customers")
      assert result == {:error, "Expected format: collection(key)"}
    end

    test "returns error for empty key" do
      result = NavigationResolver.parse_collection_and_key("customers()")
      assert result == {:error, "Expected format: collection(key)"}
    end

    test "returns error for missing collection name" do
      result = NavigationResolver.parse_collection_and_key("(123)")
      assert result == {:error, "Expected format: collection(key)"}
    end

    test "returns error for collection name starting with number" do
      result = NavigationResolver.parse_collection_and_key("1customers(123)")
      assert result == {:error, "Expected format: collection(key)"}
    end

    test "returns error for special characters in collection name" do
      result = NavigationResolver.parse_collection_and_key("cust-omers(123)")
      assert result == {:error, "Expected format: collection(key)"}
    end

    test "returns error for unclosed parenthesis" do
      result = NavigationResolver.parse_collection_and_key("customers(123")
      assert result == {:error, "Expected format: collection(key)"}
    end
  end

  describe "parse_reference_spec/1" do
    test "parses simple table and column reference" do
      result = NavigationResolver.parse_reference_spec("customers(id)")
      assert result == {:ok, {"customers", "id"}}
    end

    test "parses schema qualified table reference" do
      result = NavigationResolver.parse_reference_spec("sales_test.customers(id)")
      assert result == {:ok, {"sales_test.customers", "id"}}
    end

    test "parses table with underscores" do
      result = NavigationResolver.parse_reference_spec("order_items(order_id)")
      assert result == {:ok, {"order_items", "order_id"}}
    end

    test "parses column with underscores" do
      result = NavigationResolver.parse_reference_spec("products(category_id)")
      assert result == {:ok, {"products", "category_id"}}
    end

    test "parses fully qualified reference with dots" do
      result = NavigationResolver.parse_reference_spec("public.sales.customers(customer_id)")
      assert result == {:ok, {"public.sales.customers", "customer_id"}}
    end

    test "returns error for invalid format without parentheses" do
      result = NavigationResolver.parse_reference_spec("customers")

      assert result ==
               {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end

    test "returns error for empty column" do
      result = NavigationResolver.parse_reference_spec("customers()")

      assert result ==
               {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end

    test "returns error for missing table name" do
      result = NavigationResolver.parse_reference_spec("(id)")

      assert result ==
               {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end

    test "returns error for special characters in table name" do
      result = NavigationResolver.parse_reference_spec("cust-omers(id)")

      assert result ==
               {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end

    test "returns error for special characters in column name" do
      result = NavigationResolver.parse_reference_spec("customers(id-field)")

      assert result ==
               {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end

    test "returns error for unclosed parenthesis" do
      result = NavigationResolver.parse_reference_spec("customers(id")

      assert result ==
               {:error, "Invalid format. Expected 'table(column)' or 'schema.table(column)'"}
    end
  end

  describe "find_reference_for_navigation/2" do
    test "finds matching reference for navigation property" do
      references = [
        %{"col" => "customer_id", "ref" => "customers(id)"},
        %{"col" => "product_id", "ref" => "products(id)"}
      ]

      result = NavigationResolver.find_reference_for_navigation(references, "Customers")
      assert {:ok, %{"col" => "customer_id", "ref" => "customers(id)"}} = result
    end

    test "finds reference with schema qualification" do
      references = [
        %{"col" => "customer_id", "ref" => "sales.customers(id)"},
        %{"col" => "product_id", "ref" => "inventory.products(id)"}
      ]

      result = NavigationResolver.find_reference_for_navigation(references, "Customers")
      assert {:ok, %{"col" => "customer_id", "ref" => "sales.customers(id)"}} = result
    end

    test "matches navigation property case insensitively" do
      references = [
        %{"col" => "customer_id", "ref" => "customers(id)"}
      ]

      result1 = NavigationResolver.find_reference_for_navigation(references, "customers")
      result2 = NavigationResolver.find_reference_for_navigation(references, "CUSTOMERS")
      result3 = NavigationResolver.find_reference_for_navigation(references, "Customers")

      expected = {:ok, %{"col" => "customer_id", "ref" => "customers(id)"}}
      assert result1 == expected
      assert result2 == expected
      assert result3 == expected
    end

    test "returns error when no matching reference found" do
      references = [
        %{"col" => "customer_id", "ref" => "customers(id)"},
        %{"col" => "product_id", "ref" => "products(id)"}
      ]

      result = NavigationResolver.find_reference_for_navigation(references, "Orders")
      assert result == {:error, :no_reference}
    end

    test "handles empty references list" do
      references = []

      result = NavigationResolver.find_reference_for_navigation(references, "Customers")
      assert result == {:error, :no_reference}
    end

    test "handles invalid reference specifications gracefully" do
      references = [
        %{"col" => "customer_id", "ref" => "invalid-format"},
        %{"col" => "product_id", "ref" => "products(id)"}
      ]

      # Should skip invalid reference and continue searching
      result = NavigationResolver.find_reference_for_navigation(references, "Products")
      assert {:ok, %{"col" => "product_id", "ref" => "products(id)"}} = result
    end

    test "matches table name after stripping schema prefix" do
      references = [
        %{"col" => "customer_id", "ref" => "sales_test.customers(id)"}
      ]

      result = NavigationResolver.find_reference_for_navigation(references, "Customers")
      assert {:ok, %{"col" => "customer_id", "ref" => "sales_test.customers(id)"}} = result
    end

    test "handles underscore in table names" do
      references = [
        %{"col" => "order_item_id", "ref" => "order_items(id)"}
      ]

      # Should match "Order_items" to "order_items"
      result = NavigationResolver.find_reference_for_navigation(references, "Order_items")
      assert {:ok, %{"col" => "order_item_id", "ref" => "order_items(id)"}} = result
    end
  end

  # Note: Integration tests for handle_navigation_request/5 and execute_navigation_query/6 
  # would require mocking Phoenix.Controller, Plug.Conn, and Modeta.Cache which is better 
  # done in controller integration tests. These functions are primarily orchestration
  # and response building which are tested through the full OData system.

  describe "integration behavior" do
    test "parse_collection_and_key integrates with find_reference_for_navigation workflow" do
      # Test the typical workflow of parsing a navigation URL
      collection_with_key = "purchases(1)"

      {:ok, collection_name, key} =
        NavigationResolver.parse_collection_and_key(collection_with_key)

      # Verify parsed values can be used in subsequent operations
      assert collection_name == "purchases"
      assert key == "1"

      # Test with typical references
      references = [%{"col" => "customer_id", "ref" => "customers(id)"}]
      nav_result = NavigationResolver.find_reference_for_navigation(references, "Customers")

      assert {:ok, _reference} = nav_result
    end

    test "parse_reference_spec integrates with navigation property resolution" do
      # Test that parsed reference specs work with navigation logic
      ref_spec = "sales_test.customers(id)"
      {:ok, {table, column}} = NavigationResolver.parse_reference_spec(ref_spec)

      assert table == "sales_test.customers"
      assert column == "id"

      # Verify table name extraction for navigation matching
      table_name = table |> String.split(".") |> List.last()
      assert table_name == "customers"
    end

    test "error handling propagates correctly through parsing chain" do
      # Test error propagation in navigation resolution workflow

      # Invalid collection format should return error
      assert {:error, _} = NavigationResolver.parse_collection_and_key("invalid")

      # Invalid reference format should return error  
      assert {:error, _} = NavigationResolver.parse_reference_spec("invalid")

      # Missing navigation property should return error
      assert {:error, :no_reference} =
               NavigationResolver.find_reference_for_navigation([], "Missing")
    end
  end
end
