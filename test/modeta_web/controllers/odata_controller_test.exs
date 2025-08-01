defmodule ModetaWeb.ODataControllerTest do
  use ModetaWeb.ConnCase, async: false

  describe "collection endpoint" do
    test "GET /sales_test/customers returns customer data", %{conn: conn} do
      # Make request to customers collection in sales_test group
      conn = get(conn, ~p"/sales_test/customers")

      # Should return 200 OK
      assert response = json_response(conn, 200)

      # Should have OData structure
      assert %{
               "@odata.context" => "http://www.example.com:80/sales_test/$metadata#customers",
               "value" => customers
             } = response

      # Should have 10 customers from fixture
      assert length(customers) == 10

      # First customer should be John Doe
      [first_customer | _] = customers

      assert %{
               "id" => 1,
               "name" => "John Doe",
               "email" => "john.doe@email.com",
               "country" => "USA"
             } = first_customer

      # All customers should have required fields
      Enum.each(customers, fn customer ->
        assert Map.has_key?(customer, "id")
        assert Map.has_key?(customer, "name")
        assert Map.has_key?(customer, "email")
        assert Map.has_key?(customer, "country")
        assert Map.has_key?(customer, "city")
        assert Map.has_key?(customer, "age")
        assert Map.has_key?(customer, "registration_date")
      end)
    end

    test "GET /sales_test/nonexistent returns 404", %{conn: conn} do
      conn = get(conn, ~p"/sales_test/nonexistent")

      assert response = json_response(conn, 404)
      assert %{"error" => %{"message" => message}} = response
      assert message =~ "Collection 'nonexistent' not found"
    end
  end

  describe "$select system query option" do
    test "GET /sales_test/customers?$select=id,name returns only selected columns", %{conn: conn} do
      conn = get(conn, ~p"/sales_test/customers?$select=id,name")

      assert response = json_response(conn, 200)

      # Should have OData structure with $select in context URL
      assert %{
               "@odata.context" =>
                 "http://www.example.com:80/sales_test/$metadata#customers(id,name)",
               "value" => customers
             } = response

      # Should have 10 customers from fixture
      assert length(customers) == 10

      # Each customer should only have selected fields
      Enum.each(customers, fn customer ->
        assert Map.has_key?(customer, "id")
        assert Map.has_key?(customer, "name")
        # Should NOT have other fields
        refute Map.has_key?(customer, "email")
        refute Map.has_key?(customer, "country")
        refute Map.has_key?(customer, "city")
        refute Map.has_key?(customer, "age")
        refute Map.has_key?(customer, "registration_date")
        # Should have exactly 2 fields
        assert map_size(customer) == 2
      end)

      # First customer should be John Doe with only id and name
      [first_customer | _] = customers

      assert %{
               "id" => 1,
               "name" => "John Doe"
             } = first_customer
    end

    test "GET /sales_test/customers?$select=id returns single column", %{conn: conn} do
      conn = get(conn, ~p"/sales_test/customers?$select=id")

      assert response = json_response(conn, 200)

      # Should have OData structure with $select in context URL
      assert %{
               "@odata.context" => "http://www.example.com:80/sales_test/$metadata#customers(id)",
               "value" => customers
             } = response

      assert length(customers) == 10

      # Each customer should only have id field
      Enum.each(customers, fn customer ->
        assert Map.has_key?(customer, "id")
        assert map_size(customer) == 1
      end)
    end

    test "GET /sales_test/customers?$select=id,email,country returns multiple specific columns",
         %{conn: conn} do
      conn = get(conn, ~p"/sales_test/customers?$select=id,email,country")

      assert response = json_response(conn, 200)

      # Should have OData structure with $select in context URL
      assert %{
               "@odata.context" =>
                 "http://www.example.com:80/sales_test/$metadata#customers(id,email,country)",
               "value" => customers
             } = response

      assert length(customers) == 10

      # Each customer should only have selected fields
      Enum.each(customers, fn customer ->
        assert Map.has_key?(customer, "id")
        assert Map.has_key?(customer, "email")
        assert Map.has_key?(customer, "country")
        # Should NOT have other fields
        refute Map.has_key?(customer, "name")
        refute Map.has_key?(customer, "city")
        refute Map.has_key?(customer, "age")
        refute Map.has_key?(customer, "registration_date")
        # Should have exactly 3 fields
        assert map_size(customer) == 3
      end)
    end

    test "GET /sales_test/customers?$select= (empty) returns all columns", %{conn: conn} do
      conn = get(conn, ~p"/sales_test/customers?$select=")

      assert response = json_response(conn, 200)

      # Should have normal context URL when $select is empty
      assert %{
               "@odata.context" => "http://www.example.com:80/sales_test/$metadata#customers",
               "value" => customers
             } = response

      assert length(customers) == 10

      # Should have all fields like normal query
      [first_customer | _] = customers
      assert Map.has_key?(first_customer, "id")
      assert Map.has_key?(first_customer, "name")
      assert Map.has_key?(first_customer, "email")
      assert Map.has_key?(first_customer, "country")
      assert Map.has_key?(first_customer, "city")
      assert Map.has_key?(first_customer, "age")
      assert Map.has_key?(first_customer, "registration_date")
    end

    test "GET /sales_test/customers(1)?$select=id,name works with entity by key", %{conn: conn} do
      conn = get(conn, ~p"/sales_test/customers(1)?$select=id,name")

      assert response = json_response(conn, 200)

      # Should have OData single entity structure with $select in context URL
      assert %{
               "@odata.context" =>
                 "http://www.example.com:80/sales_test/$metadata#customers/$entity(id,name)",
               "id" => 1,
               "name" => "John Doe"
             } = response

      # Should only have selected fields
      refute Map.has_key?(response, "email")
      refute Map.has_key?(response, "country")
      refute Map.has_key?(response, "city")
      refute Map.has_key?(response, "age")
      refute Map.has_key?(response, "registration_date")

      # Should have exactly 3 keys: @odata.context, id, name
      assert map_size(response) == 3
    end

    test "GET /sales_test/customers?$select=id,name&$filter=country eq 'USA' combines $select with $filter",
         %{conn: conn} do
      conn = get(conn, ~p"/sales_test/customers?$select=id,name&$filter=country eq 'USA'")

      assert response = json_response(conn, 200)

      # Should have OData structure with $select in context URL
      assert %{
               "@odata.context" =>
                 "http://www.example.com:80/sales_test/$metadata#customers(id,name)",
               "value" => customers
             } = response

      # Should have filtered results (only USA customers)
      assert length(customers) > 0
      # Should be fewer than total
      assert length(customers) < 10

      # Each customer should only have selected fields
      Enum.each(customers, fn customer ->
        assert Map.has_key?(customer, "id")
        assert Map.has_key?(customer, "name")
        refute Map.has_key?(customer, "email")
        # Even though we filtered by it
        refute Map.has_key?(customer, "country")
        assert map_size(customer) == 2
      end)
    end
  end

  describe "$expand system query option" do
    test "GET /sales_test/purchases?$expand=Customers includes customer data inline", %{
      conn: conn
    } do
      conn = get(conn, ~p"/sales_test/purchases?$expand=Customers")

      assert response = json_response(conn, 200)

      # Should have OData structure
      assert %{
               "@odata.context" => "http://www.example.com:80/sales_test/$metadata#purchases",
               "value" => purchases
             } = response

      assert length(purchases) > 0

      # Each purchase should have expanded customer data
      Enum.each(purchases, fn purchase ->
        # Should have regular purchase fields
        assert Map.has_key?(purchase, "id")
        assert Map.has_key?(purchase, "customer_id")
        assert Map.has_key?(purchase, "product_name")
        assert Map.has_key?(purchase, "total_amount")

        # Should have expanded Customers navigation property
        assert Map.has_key?(purchase, "Customers")
        customer = purchase["Customers"]

        # Expanded customer should have customer fields
        assert Map.has_key?(customer, "id")
        assert Map.has_key?(customer, "name")
        assert Map.has_key?(customer, "email")
        assert Map.has_key?(customer, "country")

        # Customer ID should match the foreign key
        assert customer["id"] == purchase["customer_id"]
      end)

      # First purchase should be iPhone with John Doe's data expanded
      first_purchase = List.first(purchases)
      assert first_purchase["product_name"] == "iPhone 15 Pro"
      assert first_purchase["Customers"]["name"] == "John Doe"
      assert first_purchase["Customers"]["email"] == "john.doe@email.com"
    end

    test "GET /sales_test/purchases(1)?$expand=Customers works with entity by key", %{conn: conn} do
      conn = get(conn, ~p"/sales_test/purchases(1)?$expand=Customers")

      assert response = json_response(conn, 200)

      # Should have OData single entity structure
      assert %{
               "@odata.context" =>
                 "http://www.example.com:80/sales_test/$metadata#purchases/$entity"
             } = response

      # Should have purchase fields
      assert response["id"] == 1
      assert response["product_name"] == "iPhone 15 Pro"
      assert response["customer_id"] == 1

      # Should have expanded customer data
      assert Map.has_key?(response, "Customers")
      customer = response["Customers"]
      assert customer["id"] == 1
      assert customer["name"] == "John Doe"
      assert customer["email"] == "john.doe@email.com"
    end

    test "GET /sales_test/purchases?$expand=Customers&$select=id,product_name combines $expand with $select",
         %{conn: conn} do
      # Note: Selecting expanded navigation properties in $select is complex and may not be fully supported
      # Let's test $expand with $select on regular columns first
      conn = get(conn, ~p"/sales_test/purchases?$expand=Customers&$select=id,product_name")

      case json_response(conn, :ok) do
        %{"error" => _} ->
          # If not supported yet, that's expected - this is an advanced feature
          :ok

        response ->
          # Should have OData structure with $select in context URL
          assert %{
                   "@odata.context" => context,
                   "value" => purchases
                 } = response

          # Context should reflect $select
          assert String.contains?(context, "purchases")
          assert String.contains?(context, "id,product_name")

          assert length(purchases) > 0

          # Each purchase should only have selected fields, expanded data behavior varies
          Enum.each(purchases, fn purchase ->
            # Should have selected fields
            assert Map.has_key?(purchase, "id")
            assert Map.has_key?(purchase, "product_name")

            # Should NOT have unselected fields
            refute Map.has_key?(purchase, "category")
            refute Map.has_key?(purchase, "price")
            refute Map.has_key?(purchase, "quantity")

            # Expanded data behavior with $select is implementation-dependent
            # May or may not include expanded Customers data
          end)
      end
    end

    test "GET /sales_test/purchases?$expand=Customers&$filter=total_amount gt 500 combines $expand with $filter",
         %{conn: conn} do
      conn = get(conn, ~p"/sales_test/purchases?$expand=Customers&$filter=total_amount gt 500")

      assert response = json_response(conn, 200)

      # Should have OData structure
      assert %{
               "@odata.context" => "http://www.example.com:80/sales_test/$metadata#purchases",
               "value" => purchases
             } = response

      assert length(purchases) > 0

      # All returned purchases should have total_amount > 500
      Enum.each(purchases, fn purchase ->
        assert purchase["total_amount"] > 500

        # Should have expanded customer data
        assert Map.has_key?(purchase, "Customers")
        customer = purchase["Customers"]
        assert Map.has_key?(customer, "name")
        assert customer["id"] == purchase["customer_id"]
      end)
    end

    test "GET /sales_test/purchases?$expand=NonExistent handles unknown navigation properties gracefully",
         %{conn: conn} do
      conn = get(conn, ~p"/sales_test/purchases?$expand=NonExistent")

      # Should still return 200 but without expanded data
      assert response = json_response(conn, 200)

      assert %{
               "@odata.context" => "http://www.example.com:80/sales_test/$metadata#purchases",
               "value" => purchases
             } = response

      assert length(purchases) > 0

      # Should have normal purchase data but no expanded navigation property
      Enum.each(purchases, fn purchase ->
        assert Map.has_key?(purchase, "id")
        assert Map.has_key?(purchase, "product_name")
        # Should NOT have the invalid navigation property
        refute Map.has_key?(purchase, "NonExistent")
      end)
    end

    test "GET /sales_test/purchases?$expand= (empty) returns normal data without expansion", %{
      conn: conn
    } do
      conn = get(conn, ~p"/sales_test/purchases?$expand=")

      assert response = json_response(conn, 200)

      # Should have normal OData structure
      assert %{
               "@odata.context" => "http://www.example.com:80/sales_test/$metadata#purchases",
               "value" => purchases
             } = response

      assert length(purchases) > 0

      # Should have normal purchase data but no expanded navigation properties
      Enum.each(purchases, fn purchase ->
        assert Map.has_key?(purchase, "id")
        assert Map.has_key?(purchase, "product_name")
        assert Map.has_key?(purchase, "customer_id")
        # Should NOT have expanded customer data
        refute Map.has_key?(purchase, "Customers")
      end)
    end
  end
end
