import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :modeta, ModetaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "q88/Yqa2DK6Au76zQy2ROfdmTk9m13HXxgtmgFoJjcgysr/HOdqUf8KwDwdhBApM",
  server: false

# Use separate collections file for testing
config :modeta,
  collections_file: "config/collections_test.yml"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
