import Config

config :noxir, :information,
  name: "Noxir",
  description: "The Nostr relay implemented in Elixir.",
  pubkey: nil,
  contact: nil,
  software: "https://github.com/kphrx/noxir"

config :noxir, :auth,
  required: false,
  allowed_pubkeys: []

import_config "#{config_env()}.exs"
