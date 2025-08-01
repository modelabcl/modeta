defmodule ModetaWeb.Router do
  use ModetaWeb, :router

  pipeline :api do
    plug(:accepts, ["json", "xml", "atom", "atomsvc"])
  end

  scope "/modeta", ModetaWeb do
    pipe_through(:api)

    # OData required endpoints
    get("/$metadata", ODataController, :metadata)
    get("/", ODataController, :service_document)

    # Dynamic routes for OData collections
    get("/:collection", ODataController, :collection)
  end
end
