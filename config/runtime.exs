import Config

config :noxir, :standalone, true

information =
  Keyword.filter(
    [
      name: System.get_env("RELAY_NAME"),
      description: System.get_env("RELAY_DESC"),
      pubkey: System.get_env("OWNER_PUBKEY"),
      contact: System.get_env("OWNER_CONTACT")
    ],
    fn {_, v} -> !is_nil(v) end
  )

config :noxir, :information, information

auth_required = System.get_env("AUTH_REQUIRED", "false") |> String.downcase() == "true"

allowed_pubkeys =
  case System.get_env("ALLOWED_PUBKEYS") do
    nil -> []
    pubkeys -> String.split(pubkeys, ",") |> Enum.map(&String.trim/1)
  end

config :noxir, :policy_opts,
  required: auth_required,
  allowed_pubkeys: allowed_pubkeys

if port = System.get_env("PORT", "4000") |> Integer.parse() do
  config :noxir, :port, port |> elem(0)
end

if max_conn = System.get_env("MAX_CONNECTIONS", "10000") |> Integer.parse() do
  config :noxir, :max_connections, max_conn |> elem(0)
end

if max_subs = System.get_env("MAX_SUBSCRIPTIONS_PER_CONNECTION", "100") |> Integer.parse() do
  config :noxir, :max_subscriptions_per_connection, max_subs |> elem(0)
end

if max_events = System.get_env("MAX_EVENTS_PER_MINUTE", "1000") |> Integer.parse() do
  config :noxir, :max_events_per_minute, max_events |> elem(0)
end
