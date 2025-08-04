import Config

# Production-specific DuckDB database path
config :modeta, duckdb_path: "data/modeta_prod.duckdb"

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
