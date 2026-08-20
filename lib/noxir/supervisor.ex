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
    * `:policy_opts` — opts for `Noxir.Policy.impl().init/1`
    * `:max_connections` — max concurrent WebSocket connections (default: `10_000` or `config :noxir, :max_connections`)
    * `:max_subscriptions_per_connection` — per-conn sub cap (default: `100` or `config :noxir, :max_subscriptions_per_connection`)
    * `:name` — supervisor name (default: `Noxir.Supervisor`)
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
end
