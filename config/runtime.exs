import Config

# Standalone boot (own supervision tree + Bandit); never in the test environment,
# which starts `Noxir.Supervisor` explicitly via test/test_helper.exs.
if config_env() != :test do
  config :noxir, :standalone, true
end

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

# INDEX_KEYS_REQUIRED: comma-separated list of index keys that REQ filters
# must include (e.g. "authors,#h" or "authors,kinds"). Unset: derives from
# SUBSCRIPTION_INDEX_KEYS. Empty string disables the requirement.
index_keys_required =
  case System.get_env("INDEX_KEYS_REQUIRED") do
    nil -> nil
    "" -> []
    keys ->
      keys
      |> String.split(",")
      |> Enum.map(fn key ->
        key = String.trim(key)
        if String.starts_with?(key, "#") do
          :"#{key}"
        else
          String.to_existing_atom(key)
        end
      end)
  end

policy_opts = [required: auth_required, allowed_pubkeys: allowed_pubkeys]

policy_opts =
  if index_keys_required do
    Keyword.put(policy_opts, :index_keys_required, index_keys_required)
  else
    policy_opts
  end

config :noxir, :policy_opts, policy_opts

# SUBSCRIPTION_INDEX_KEYS: comma-separated index keys to route subscriptions by
# (pg groups). Any "#x" tag key works — e.g. "authors,#h,#e,#p" to also accept
# thread (#e) and mention (#p) REQs. Default: [:authors].
subscription_index_keys =
  case System.get_env("SUBSCRIPTION_INDEX_KEYS", "authors,#h") do
    "" -> []
    keys ->
      keys
      |> String.split(",")
      |> Enum.map(fn key ->
        key = String.trim(key)
        if String.starts_with?(key, "#") do
          :"#{key}"
        else
          String.to_existing_atom(key)
        end
      end)
  end

config :noxir, :subscription_index_keys, subscription_index_keys

if port = System.get_env("PORT", "4000") |> Integer.parse() do
  config :noxir, :port, port |> elem(0)
end

if max_conn = System.get_env("MAX_CONNECTIONS", "10000") |> Integer.parse() do
  config :noxir, :max_connections, max_conn |> elem(0)
end

# Connection limits: per-connection subscription cap and token-bucket EVENT rate
# limit. `MAX_EVENTS_PER_MINUTE=0` disables rate limiting.
limits =
  [
    {:max_subscriptions_per_connection, System.get_env("MAX_SUBSCRIPTIONS_PER_CONNECTION", "100")},
    {:max_events_per_minute, System.get_env("MAX_EVENTS_PER_MINUTE", "1000")}
  ]
  |> Enum.flat_map(fn {key, value} ->
    case Integer.parse(value) do
      {n, _} -> [{key, n}]
      :error -> []
    end
  end)

config :noxir, :limits, limits
