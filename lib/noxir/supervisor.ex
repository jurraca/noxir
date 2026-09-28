defmodule Noxir.Supervisor do
  @moduledoc """
  Supervision tree for Noxir relay components.

  ## Standalone mode

      config :noxir, :standalone, true

  `Noxir.Application` starts this supervisor with `start_bandit: true`.

  ## Embedded mode

  Add to your host app's supervision tree:

      children = [
        MyApp.Repo,
        {Noxir.Supervisor, start_bandit: false},
        {Bandit, scheme: :http, plug: MyAppWeb.Endpoint, port: 4000}
      ]

  Or let Noxir own HTTP:

      children = [
        {Noxir.Supervisor, start_bandit: true, port: 4000}
      ]

  ## Options

    * `:start_bandit` — start Bandit with `Noxir.Router` (default: `false`)
    * `:port` — HTTP port (default: `4000` or `config :noxir, :port`)
    * `:plug` — custom plug for Bandit (default: `Noxir.Router`)
    * `:store` — store module (default: `config :noxir, :store` or `Noxir.Store.ETS`)
    * `:store_opts` — opts for the store's `child_spec/1` (default: `config :noxir, :store_opts` or `[]`; e.g. `[repo: MyApp.Repo]` or `[disc: true, mnesia_dir: "priv/mnesia"]`)
    * `:policy_opts` — opts for `Noxir.Policy.impl().init/1`
    * `:max_connections` — max concurrent WebSocket connections (default: `10_000` or `config :noxir, :max_connections`)
    * `:name` — supervisor name (default: `Noxir.Supervisor`)

  Connection limits are not supervisor options — they are resolved per
  connection from `config :noxir, :limits` app env (default:
  `[max_subscriptions_per_connection: 100, max_events_per_minute: 1000]`),
  overridable via the WebSock init opts passed to `WebSockAdapter.upgrade/4`.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    policy = Noxir.Policy.impl()

    policy.init(
      Keyword.get(opts, :policy_opts, Application.get_env(:noxir, :policy_opts, []))
    )

    validate_index_config!(policy)

    store = Keyword.get(opts, :store, Noxir.Store.impl())
    start_bandit = Keyword.get(opts, :start_bandit, false)
    port = Keyword.get(opts, :port, Application.get_env(:noxir, :port, 4000))
    plug = Keyword.get(opts, :plug, Noxir.Router)
    max_connections = Keyword.get(opts, :max_connections, Application.get_env(:noxir, :max_connections, 10_000))

    children = [
      {Noxir.SubscriptionRegistry.Owner, []},
      store.child_spec([])
    ]

    children =
      if start_bandit do
        children ++
          [
            {Bandit,
             scheme: :http,
             plug: plug,
             port: port,
             thousand_island_options: [num_connections: max_connections]}
          ]
      else
        children
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Fails fast when required index keys aren't in the subscription index keys.

  A requirement that isn't routed makes affected subscriptions silently deaf
  (no pg group to join), so misconfiguration is a boot error, not a warning.
  """
  @spec validate_index_config!(policy :: module()) :: :ok
  def validate_index_config!(policy \\ Noxir.Policy.impl()) do
    required = policy.index_keys_required?()
    indexed = Noxir.SubscriptionRegistry.index_keys()
    unknown = required -- indexed

    if unknown != [] do
      raise ArgumentError, """
      index_keys_required #{inspect(required)} includes keys that are not in \
      subscription_index_keys #{inspect(indexed)}: #{inspect(unknown)}.

      Subscriptions matching only these keys would receive no live events. \
      Add the keys to :subscription_index_keys or remove them from the requirement.
      """
    end

    :ok
  end
end
