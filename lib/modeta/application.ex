defmodule Modeta.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Create DuckDB database first
    case create_duckdb_database() do
      {:ok, ddb} ->
        children = [
          ModetaWeb.Telemetry,
          {DNSCluster, query: Application.get_env(:modeta, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Modeta.PubSub},
          {Modeta.Cache, ddb},
          # Start a worker by calling: Modeta.Worker.start_link(arg)
          # {Modeta.Worker, arg},
          # Start to serve requests, typically the last entry
          ModetaWeb.Endpoint
        ]

        # See https://hexdocs.pm/elixir/Supervisor.html
        # for other strategies and supported options
        opts = [strategy: :one_for_one, name: Modeta.Supervisor]

        case Supervisor.start_link(children, opts) do
          {:ok, pid} ->
            # Initialize data structures after supervisor starts
            Modeta.DataLoader.initialize()
            {:ok, pid}

          error ->
            error
        end

      {:error, reason} ->
        {:error, {:duckdb_init_failed, reason}}
    end
  end

  # Create DuckDB database and install JSON extension
  defp create_duckdb_database do
    # Get database path from config with environment-specific fallback
    env = Mix.env()
    default_path = "data/modeta_#{env}.duckdb"
    db_path = Application.get_env(:modeta, :duckdb_path, default_path)
    absolute_path = Path.expand(db_path)

    # Ensure directory exists
    absolute_path |> Path.dirname() |> File.mkdir_p!()

    require Logger
    Logger.info("Opening DuckDB database at: #{absolute_path} (#{env} environment)")

    case Duckdbex.open(absolute_path) do
      {:ok, ddb} ->
        case install_json_extension_on_database(ddb) do
          :ok ->
            {:ok, ddb}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Install JSON extension and enable auto-loading on the database
  defp install_json_extension_on_database(ddb) do
    with {:ok, conn} <- Duckdbex.connection(ddb),
         {:ok, _} <- Duckdbex.query(conn, "SET autoinstall_known_extensions=1"),
         {:ok, _} <- Duckdbex.query(conn, "SET autoload_known_extensions=1"),
         {:ok, _} <- Duckdbex.query(conn, "INSTALL JSON"),
         {:ok, _} <- Duckdbex.query(conn, "LOAD JSON") do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ModetaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
