# Noxir

[![CI](https://github.com/jurraca/noxir/actions/workflows/elixir.yml/badge.svg)](https://github.com/jurraca/noxir/actions/workflows/elixir.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-informational.svg)](LICENSE)

Noxir is a [Nostr](https://nostr.com) relay in Elixir. A relay receives and
serves [Nostr](https://github.com/nostr-protocol/nips) events: it accepts
signed events from clients over WebSocket (NIP-01), validates and stores
them, and streams matching events back to subscribed clients.

Run Noxir standalone — it owns HTTP, storage, and its supervision tree — or
embed it in another Elixir application and start only the parts you need.

Forked from kphrx's [noxir](https://github.com/kphrx/noxir).

## Contents

- [Supported NIPs](#supported-nips)
- [Features](#features)
- [Quick start](#quick-start)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [Storage backends](#storage-backends)
- [Architecture](#architecture)
- [Development](#development)
- [License](#license)

## Supported NIPs

| NIP | Feature |
|-----|---------|
| [01](https://github.com/nostr-protocol/nips/blob/master/01.md) | Basic protocol: EVENT, REQ, CLOSE; OK, EOSE, NOTICE |
| [09](https://github.com/nostr-protocol/nips/blob/master/09.md) | Deletion requests (kind 5 with `e`/`a` tags) |
| [11](https://github.com/nostr-protocol/nips/blob/master/11.md) | Relay information document |
| [16](https://github.com/nostr-protocol/nips/blob/master/16.md) | Event kind treatment: regular, ephemeral, replaceable |
| [42](https://github.com/nostr-protocol/nips/blob/master/42.md) | Client authentication |

## Features

- `WebSock` handler on [Bandit](https://github.com/mtrudel/bandit) (pure Elixir HTTP/WebSocket)
- [NostrCore](https://github.com/jurraca/nostr_core) for event validation, wire parsing, Schnorr crypto
- Pluggable storage: ETS (default, zero deps), Mnesia, SQLite, Postgres
- `pg`-based subscription fan-out with per-connection filter matching
- Token-bucket rate limiting, connection and subscription caps

## Quick start

Run the relay from source:

```console
$ mix deps.get
$ mix run --no-halt
# relay listening on ws://localhost:4000
```

Check the NIP-11 relay information document:

```console
$ curl -s -H 'accept: application/nostr+json' http://localhost:4000
{
  "name": "Noxir",
  "description": "The Nostr relay implemented in Elixir.",
  "supported_nips": [1, 11, 42],
  "software": "https://github.com/jurraca/noxir",
  ...
}
```

Talk the raw protocol with [websocat](https://github.com/vi/websocat). By
default REQ filters must include at least one indexed key — an `authors` list
or a `#x` tag (see [`INDEX_KEYS_REQUIRED`](#configuration)):

```console
$ websocat ws://localhost:4000
["REQ","demo",{"kinds":[1],"authors":["3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"]}]
["EOSE","demo"]
```

Stored matches arrive as `["EVENT","demo",{...}]` before the `EOSE`; new
events stream live for as long as the subscription stays open.

Publishing needs a Nostr client — EVENTs must carry a valid Schnorr
signature, which a shell can't produce. Point your client at
`ws://localhost:4000`; a successful publish is answered with
`["OK","<event_id>",true,""]`.

To deploy, build a release:

```console
$ MIX_ENV=prod mix release
$ _build/prod/rel/noxir/bin/noxir start
```

## Installation

Noxir runs on Elixir >= 1.18. We recommend Elixir 1.20 with OTP 29. Add it as a dependency:

```elixir
def deps do
  [
    {:noxir, github: "jurraca/noxir"}
  ]
end
```

Optional store backends use optional deps — add the ones for your store
(`:memento` for Mnesia, `:ecto_sql` + `:postgrex` for Postgres,
`:ecto_sqlite3` for SQLite) to your own `deps`.

## Usage

### Standalone

In standalone mode (`config :noxir, :standalone, true`), `Noxir.Application`
starts the full supervision tree — subscription registry, store, Bandit — on
boot. The bundled configs enable it, so [Quick start](#quick-start) just
works. Configure via environment variables (see
[Configuration](#configuration)).

### Embedded in a host application

As a dependency, noxir starts nothing on its own: `:standalone` defaults to
`false` and `Noxir.Application` starts an empty supervisor. Add
`Noxir.Supervisor` to your app's supervision tree.

Note: env vars like `RELAY_NAME` only apply standalone — as a dependency,
noxir's `runtime.exs` is not evaluated. Configure via `config :noxir` in the
host instead (see [Configuration](#configuration)).

**Noxir owns HTTP (convenience):**

```elixir
children = [
  {Noxir.Supervisor, start_bandit: true, port: 4000}
]
```

**Host owns HTTP (e.g. a Phoenix app):**

```elixir
# config/config.exs
config :noxir, :store, Noxir.Store.Postgres
config :noxir, :store_opts, repo: MyApp.Repo

# application.ex
children = [
  MyApp.Repo,
  {Noxir.Supervisor, start_bandit: false},
  {Bandit, scheme: :http, plug: MyAppWeb.Endpoint, port: 4000}
]
```

Upgrade WebSocket connections to the relay handler in your own Plug pipeline
(this mirrors `Noxir.Router`):

```elixir
plug Noxir.Plug.WebSocket, Noxir.Relay.Socket
plug Noxir.Plug.NIP11          # optional: serve the NIP-11 doc on `Accept`
```

**Granular — pick individual children:**

```elixir
children = [
  {Noxir.SubscriptionRegistry.Owner, []},
  Noxir.Store.ETS
  # host wires Bandit/Phoenix itself and upgrades to Noxir.Relay.Socket
]
```

### `Noxir.Supervisor` options

| Option | Default | Description |
|--------|---------|-------------|
| `:start_bandit` | `false` | Start Bandit with `Noxir.Router` |
| `:port` | `4000` | HTTP port (or `config :noxir, :port`) |
| `:plug` | `Noxir.Router` | Custom plug for Bandit |
| `:store` | `Noxir.Store.ETS` | Store module (or `config :noxir, :store`) |
| `:store_opts` | `[]` | Opts for the store's `child_spec/1` (or `config :noxir, :store_opts`; e.g. `[repo: MyApp.Repo]`, `[disc: true, mnesia_dir: "priv/mnesia"]`) |
| `:policy_opts` | `[]` | Opts for `Policy.impl().init/1` |
| `:max_connections` | `10_000` | Max concurrent WebSocket connections (or `config :noxir, :max_connections`) |
| `:name` | `Noxir.Supervisor` | Supervisor name |

Connection limits are not supervisor options — they're read once per
connection at `Noxir.Relay.Socket.init/1` from `config :noxir, :limits` app env
(default `[max_subscriptions_per_connection: 100, max_events_per_minute: 1000]`;
`0` disables rate limiting). Hosts upgrading the WebSocket themselves can
override them via the `WebSockAdapter.upgrade/4` init opts: `plug Noxir.Plug.WebSocket,
{Noxir.Relay.Socket, limits: [...]}`.

## Configuration

App env (`config :noxir`) is noxir's config surface — it's a node-wide
singleton, so there's one config per node. Where a `Noxir.Supervisor` option
exists for the same setting, the option wins; env vars (standalone only) are
runtime sugar over app env. Precedence: **supervisor opts > app env >
defaults**.

Namespaces under `config :noxir`:

- `:store` + `:store_opts` — store module and its opts (`repo:`, `disc:`, `mnesia_dir:`)
- `:policy` + `:policy_opts` — policy module and its opts (auth, allowlist, index keys)
- `:limits` — per-connection limits (`max_subscriptions_per_connection:`, `max_events_per_minute:`)
- `:information` — NIP-11 document fields (name, description, pubkey, contact)
- `:subscription_index_keys` — keys that route live events to subscribers
- `:distribution` — inter-node broadcast module
- `:port`, `:max_connections` — HTTP settings

### Environment variables (runtime, standalone only)

Each variable maps 1:1 to an app env key, so embedded hosts set the same
settings via `config :noxir`:

| Variable | App env | Default | Description |
|----------|---------|---------|-------------|
| `RELAY_NAME` | `information: name` | `"Noxir"` | NIP-11 relay name |
| `RELAY_DESC` | `information: description` | `"The Nostr relay implemented in Elixir."` | NIP-11 description |
| `OWNER_PUBKEY` | `information: pubkey` | `nil` | Owner's hex pubkey |
| `OWNER_CONTACT` | `information: contact` | `nil` | Contact URI (e.g. `mailto:...`) |
| `AUTH_REQUIRED` | `policy_opts: required` | `"false"` | Require NIP-42 AUTH |
| `ALLOWED_PUBKEYS` | `policy_opts: allowed_pubkeys` | `nil` | Comma-separated allowlist |
| `SUBSCRIPTION_INDEX_KEYS` | `:subscription_index_keys` | `"authors,#h"` | Index keys that route live events to subscribers (any `#x` tag works, e.g. `authors,#h,#e,#p`) |
| `INDEX_KEYS_REQUIRED` | `policy_opts: index_keys_required` | unset | Keys REQ filters must include (any-of). Unset: same as `SUBSCRIPTION_INDEX_KEYS`; empty string disables |
| `PORT` | `:port` | `"4000"` | HTTP/WebSocket port |
| `MAX_CONNECTIONS` | `:max_connections` | `"10000"` | Max concurrent WebSocket connections |
| `MAX_SUBSCRIPTIONS_PER_CONNECTION` | `limits: max_subscriptions_per_connection` | `"100"` | Per-connection subscription cap |
| `MAX_EVENTS_PER_MINUTE` | `limits: max_events_per_minute` | `"1000"` | Token-bucket EVENT rate limit per connection (`0` disables) |

Note: embedded defaults come from compile-time config —
`:subscription_index_keys` is `[:authors]` embedded vs `[:authors, :"#h"]`
standalone.

### Policy

The default policy (`Noxir.Policy.Default`) is backed by `:persistent_term`:
- `auth_required?` — whether NIP-42 AUTH is mandatory
- `allowed_pubkey?/1` — empty allowlist = allow all; updatable at runtime via `add_pubkey/1`, `remove_pubkey/1`, `set_pubkeys/1`, `clear_pubkeys/0`
- `index_keys_required?` — keys that REQ filters must include (any-of). Defaults to `subscription_index_keys`; `[]` disables the requirement — but then unindexed REQs get historical results without live events
- `classify_event/1` — kind 22242 and NIP-16 ephemeral → not stored

Provide a custom policy via `config :noxir, :policy, MyApp.Policy`.

### Multi-node distribution

Event fan-out to subscribers is local to each node (`SubscriptionRegistry` +
`:pg` groups + `send/2`). When the relay runs on multiple nodes behind a load
balancer, a client connected to node B won't receive events accepted on
node A unless nodes forward inserts to each other. `Noxir.Distribution` is
a behaviour so the transport stays pluggable
(PubSub, Redis, ...) and the core carries no messaging dependency.
`Noxir.Distribution.Local` (default) is a no-op for single-node setups.

Yes, `:pg` groups already span cluster nodes and `send/2` delivers to remote
pids, so cross-node dispatch mostly works without any of this. The module
is for when you'd rather route inter-node traffic through your own
backbone, or fan out once per node instead of N remote sends from the
originating node.

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

Note the behaviour only covers the send half — the receiving side is up to
the host. Subscribe to the topic and deliver locally:

```elixir
Phoenix.PubSub.subscribe(MyApp.PubSub, "noxir:events")

# in the subscriber:
{:noxir_event, event} -> Noxir.SubscriptionRegistry.dispatch(event, nil)
```

## Storage backends

| Impl | Deps | Use case |
|------|------|----------|
| `Noxir.Store.ETS` | none (default) | Dev, test, small single-node relays |
| `Noxir.Store.Mnesia` | `:memento` | Single-node with durability, BEAM-native |
| `Noxir.Store.SQLite` | `:ecto_sql`, `:ecto_sqlite3` | Single-node with durability, zero external deps |
| `Noxir.Store.Postgres` | `:ecto_sql`, `:postgrex` | Production, multi-node, large datasets |

```elixir
# ETS (default)
config :noxir, :store, Noxir.Store.ETS

# Mnesia
config :noxir, :store, Noxir.Store.Mnesia
config :noxir, :store_opts, disc: true, mnesia_dir: "priv/mnesia"  # disc_copies; omit for ram-only

# SQLite (tables created at boot; host owns the Repo supervision)
config :noxir, :store, Noxir.Store.SQLite
config :noxir, :store_opts, repo: MyApp.Repo
# MyApp.Repo is a supervised Ecto.Repo with the Ecto.Adapters.SQLite3 adapter;
# point its :database at a persistent volume, e.g. "/data/noxir.db"

# Postgres
config :noxir, :store, Noxir.Store.Postgres
config :noxir, :store_opts, repo: MyApp.Repo
```

The host app owns the `Ecto.Repo` supervision. See `Noxir.Store.Postgres` moduledoc for the schema.

## Architecture

```
Noxir.Supervisor (:rest_for_one)
├── Noxir.SubscriptionRegistry.Owner  (pg scope + ETS tables)
├── Noxir.Store.<impl>                (table/schema owner)
└── Bandit                            (HTTP + WebSocket, optional)
      └── Noxir.Relay.Socket          (per-connection WebSock handler)
```

Event flow: `Message.parse` → `Event.validate` → `Policy.classify` → `Store.insert` → `SubscriptionRegistry.dispatch` → `Distribution.broadcast`

## Development

### Mix

```console
$ mix deps.get
$ mix test
$ mix credo --strict
```

### Nix flake

```console
$ nix develop -c mix deps.get
$ nix develop -c mix test
$ nix develop -c mix credo --strict
```

### Build a release with Nix

```console
$ nix build
$ RELEASE_COOKIE=noxir ./result/bin/noxir start
```

Note: the release ships without a distribution cookie (`releases/COOKIE` is
stripped from the store path), so set `RELEASE_COOKIE` when starting.

### NixOS module

The flake exposes a NixOS module under `nixosModules.default`:

```nix
# flake.nix
inputs.noxir.url = "github:jurraca/noxir";
```

```nix
# configuration.nix
{ inputs, ... }: {
  imports = [ inputs.noxir.nixosModules.default ];

  services.noxir = {
    enable = true;
    openFirewall = true;
    relayName = "my relay";
    ownerPubkey = "<hex pubkey>";
    indexKeysRequired = [ "authors" ];
  };
}
```

Options map 1:1 to the runtime environment variables (see
[Configuration](#configuration)); any extra env vars can be set via
`services.noxir.environment`. The service runs as a dynamic user with
`StateDirectory = /var/lib/noxir` and systemd sandboxing enabled. The service
sets `RELEASE_DISTRIBUTION=none` (no epmd, no listening port) — it needs to
be unset if you use Mnesia disc tables or Erlang clustering.

## License

MIT
