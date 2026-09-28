import Config

config :noxir, :limits,
  max_subscriptions_per_connection: 100,
  max_events_per_minute: 1_000
