# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :modeta,
  generators: [timestamp_type: :utc_datetime],
  collections_file: "collections.yml",
  # OData pagination settings
  default_page_size: 1000,
  max_page_size: 5000,
  # Pagination behavior: :lazy (no auto @odata.nextLink) or :server_driven (always include @odata.nextLink)
  pagination_mode: :lazy

# Configures the endpoint
config :modeta, ModetaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ModetaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Modeta.PubSub,
  live_view: [signing_salt: "90aB+wLf"]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure MIME types for OData support
config :mime, :types, %{
  "application/xml" => ["xml"],
  "application/atom+xml" => ["atom"],
  "application/atomsvc+xml" => ["atomsvc"]
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
