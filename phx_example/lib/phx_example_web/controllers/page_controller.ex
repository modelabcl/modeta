defmodule PhxExampleWeb.PageController do
  use PhxExampleWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
