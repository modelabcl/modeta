defmodule ModetaWeb.Router do
  use ModetaWeb, :router

  pipeline :api do
    plug(:accepts, ["json", "xml", "atom", "atomsvc"])
  end

  # Dynamic routes for each collection group
  scope "/:collection_group", ModetaWeb do
    pipe_through(:api)

    # OData required endpoints
    get("/$metadata", ODataController, :metadata)
    get("/", ODataController, :service_document)

    # Dynamic routes for OData collections within the group
    get("/:collection", ODataController, :collection)

    # Navigation property routes (e.g., /purchases(1)/Customers)
    # The key will be captured as part of the collection parameter and parsed later
    get("/:collection_with_key/:navigation_property", ODataController, :navigation_property)
  end
end
