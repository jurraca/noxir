import Config

config :logger, :default_formatter,
  metadata: [:event_id]

config :noxir, :information,
  name: "Noxir",
  description: "The Nostr relay implemented in Elixir.",
  pubkey: nil,
  contact: nil,
  software: "https://github.com/jurraca/noxir"

config :noxir, :store, Noxir.Store.ETS
config :noxir, :policy, Noxir.Policy.Default
config :noxir, :policy_opts,
  required: false,
  allowed_pubkeys: []


config :noxir, :subscription_index_keys, [:authors]
config :noxir, :port, 4000
config :noxir, :max_connections, 10_000

config :noxir, :store_opts, []
config :noxir, :limits,
  max_subscriptions_per_connection: 100,
  max_events_per_minute: 1_000

import_config "#{config_env()}.exs"
