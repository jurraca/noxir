# Noxir

Nostr relay in Elixir. Pluggable storage backends, OTP supervision, NostrCore-based protocol handling.

Dual-mode: run standalone or embed in another Elixir application without auto-starting supervision trees.

## Features

- NIP-01 (protocol), NIP-11 (relay info), NIP-42 (auth), NIP-09 (deletion), NIP-16 (kind classification)
- `WebSock` handler on [Bandit](https://github.com/mtrudel/bandit) (pure Elixir HTTP/WebSocket)
- [NostrCore](https://github.com/jurraca/nostr_core) for event validation, wire parsing, Schnorr crypto
- Pluggable storage: ETS (default, zero deps), Mnesia, Postgres
- `pg`-based subscription fan-out with per-connection filter matching
- `:persistent_term` policy for lock-free auth checks
- `:rest_for_one` supervision — registry/store failures cascade correctly

## Usage

### Standalone

Run the relay directly — Noxir owns HTTP, storage, and the supervision tree.

**Nix:**

```console
$ nix run
# Relay running on port 4000
```

**Mix:**

```console
$ mix deps.get
$ mix run --no-halt
# Relay running on port 4000
```

**Release:**

```console
$ MIX_ENV=prod mix release
$ _build/prod/rel/noxir/bin/noxir start
```

### Embedded in a host application

Add noxir as a dependency. Noxir loads as a library — no processes start automatically (`Application.start/2` returns `:ignore`). Add `Noxir.Supervisor` to your app's supervision tree.

**Host owns HTTP (e.g. Phoenix app):**

```elixir
# host config
config :noxir, :store, Noxir.Store.Postgres
config :noxir, :postgres_repo, MyApp.Repo
# :standalone defaults to false — no auto-start

# host application.ex
children = [
  MyApp.Repo,
  {Noxir.Supervisor, start_bandit: false},
  {Bandit, scheme: :http, plug: MyAppWeb.Endpoint, port: 4000}
  # host upgrades WebSocket to Noxir.Relay.Socket in its own Plug pipeline
]
```

**Noxir owns HTTP (convenience):**

```elixir
children = [
  {Noxir.Supervisor, start_bandit: true, port: 4000}
]
```

**Granular — pick individual children:**

```elixir
children = [
  {Noxir.SubscriptionRegistry.Owner, []},
  Noxir.Store.ETS.child_spec([])
  # host wires Bandit/Phoenix separately, upgrades to Noxir.Relay.Socket
]
```

### `Noxir.Supervisor` options

| Option | Default | Description |
|--------|---------|-------------|
| `:start_bandit` | `false` | Start Bandit with `Noxir.Router` |
| `:port` | `4000` | HTTP port (or `config :noxir, :port`) |
| `:plug` | `Noxir.Router` | Custom plug for Bandit |
| `:store` | `Noxir.Store.ETS` | Store module (or `config :noxir, :store`) |
| `:policy_opts` | `[]` | Opts for `Policy.impl().init/1` |
| `:name` | `Noxir.Supervisor` | Supervisor name |

## Storage backends

| Impl | Deps | Use case |
|------|------|----------|
| `Noxir.Store.ETS` | none (default) | Dev, test, small single-node relays |
| `Noxir.Store.Mnesia` | `:memento` | Single-node with durability, BEAM-native |
| `Noxir.Store.Postgres` | `:ecto_sql`, `:postgrex` | Production, multi-node, large datasets |

```elixir
# ETS (default)
config :noxir, :store, Noxir.Store.ETS

# Mnesia
config :noxir, :store, Noxir.Store.Mnesia
config :noxir, :mnesia_dir, "priv/mnesia"  # disc_copies; omit for ram-only
config :noxir, :disc, true

# Postgres
config :noxir, :store, Noxir.Store.Postgres
config :noxir, :postgres_repo, MyApp.Repo
```

The host app owns the `Ecto.Repo` supervision. See `Noxir.Store.Postgres` moduledoc for the schema.

## Configuration

### Environment variables (runtime, standalone mode)

| Variable | Default | Description |
|----------|---------|-------------|
| `RELAY_NAME` | `"Noxir"` | NIP-11 relay name |
| `RELAY_DESC` | `"The Nostr relay implemented in Elixir."` | NIP-11 description |
| `OWNER_PUBKEY` | `nil` | Owner's hex pubkey |
| `OWNER_CONTACT` | `nil` | Contact URI (e.g. `mailto:...`) |
| `AUTH_REQUIRED` | `"false"` | Require NIP-42 AUTH |
| `ALLOWED_PUBKEYS` | `nil` | Comma-separated allowlist |
| `PORT` | `4000` | HTTP/WebSocket port |

### Policy

The default policy (`Noxir.Policy.Default`) is backed by `:persistent_term`:
- `auth_required?` — whether NIP-42 AUTH is mandatory
- `allowed_pubkey?/1` — empty allowlist = allow all
- `authors_required?` — all REQ filters must include `authors`
- `classify_event/1` — kind 22242 and NIP-16 ephemeral → not stored

Provide a custom policy via `config :noxir, :policy, MyApp.Policy`.

### Multi-node distribution

`Noxir.Distribution.Local` (default) is a no-op. For multi-node fan-out,
provide a PubSub-based impl:

```elixir
config :noxir, :distribution, MyApp.Distribution.PubSub
```

```elixir
defmodule MyApp.Distribution.PubSub do
  @behaviour Noxir.Distribution

  @impl true
  def broadcast(event) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "noxir:events", {:noxir_event, event})
  end
end
```

On receiving nodes, call `Noxir.SubscriptionRegistry.dispatch(event, nil)`.

## Development

### Nix flake

```console
$ nix develop -c mix deps.get
$ nix develop -c mix test
$ nix develop -c mix credo --strict
$ nix develop -c mix dialyzer
```

### Build a release

```console
$ nix build
$ ./result/bin/noxir start
```

## Architecture

```
Noxir.Supervisor (:rest_for_one)
├── Noxir.SubscriptionRegistry.Owner  (pg scope + ETS tables)
├── Noxir.Store.<impl>                (table/schema owner)
└── Bandit                            (HTTP + WebSocket, optional)
      └── Noxir.Relay.Socket          (per-connection WebSock handler)
```

Event flow: `Message.parse` → `Event.validate` → `Policy.classify` → `Store.insert` → `SubscriptionRegistry.dispatch` → `Distribution.broadcast`

## License

MIT
