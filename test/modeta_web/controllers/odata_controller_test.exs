defmodule ModetaWeb.ODataControllerTest do
  use ModetaWeb.ConnCase, async: false

  describe "collection endpoint" do
    test "GET /sales/customers returns customer data", %{conn: conn} do
      # Make request to customers collection in sales group
      conn = get(conn, ~p"/sales/customers")

      # Should return 200 OK
      assert response = json_response(conn, 200)

      # Should have OData structure
      assert %{
               "@odata.context" => "http://www.example.com:80/sales/$metadata#customers",
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

    test "GET /sales/nonexistent returns 404", %{conn: conn} do
      conn = get(conn, ~p"/sales/nonexistent")

      assert response = json_response(conn, 404)
      assert %{"error" => %{"message" => message}} = response
      assert message =~ "Collection 'nonexistent' not found"
    end
  end
end
