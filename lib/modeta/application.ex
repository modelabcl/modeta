defmodule Modeta.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ModetaWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:modeta, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Modeta.PubSub},
      Modeta.Cache,
      # Start a worker by calling: Modeta.Worker.start_link(arg)
      # {Modeta.Worker, arg},
      # Start to serve requests, typically the last entry
      ModetaWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Modeta.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ModetaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
