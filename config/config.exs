import Config

# This checkout exercises SMTP adapters and needs no HTTP API client.
config :swoosh, :api_client, false
