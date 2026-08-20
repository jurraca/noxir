# Overview

Noxir is a Nostr relay implementation written in Elixir. It handles WebSocket connections from Nostr clients, stores and retrieves events, and provides real-time message delivery per the Nostr protocol (NIP-01). Built on OTP principles with pluggable storage backends (ETS, Mnesia, Postgres) and NostrCore for protocol handling.

The application uses Bandit (pure Elixir HTTP/WebSocket server), NostrCore (event parsing, validation, Schnorr crypto), and a `pg`-based subscription registry for efficient fan-out.

# User Preferences

Preferred communication style: Simple, everyday language.

# System Architecture

## Web Server

**Bandit** (pure Elixir, on Thousand Island) handles HTTP and WebSocket. `Noxir.Router` is a Plug pipeline: CORS, NIP-11 detection, WebSocket upgrade to `Noxir.Relay.Socket`.

## Protocol Layer

**NostrCore** owns event structs, validation (Schnorr + ID), wire message parsing/encoding (NIP-01), filter parsing, and kind classification (NIP-16). Noxir does not duplicate any protocol logic.

## Storage

Pluggable via `Noxir.Store` behaviour:
- **ETS** (default, zero deps) — in-memory, for dev/test/small relays
- **Mnesia** (via Memento) — BEAM-native, disc opt-in
- **Postgres** (via Ecto) — production, large datasets

Each impl owns replaceable/parameterized event semantics internally.

## Subscription Routing

`Noxir.SubscriptionRegistry` uses `:pg` process groups keyed by author pubkey. On event insert, the registry queries the author's pg group for candidate pids, then each candidate runs `Noxir.Filter.match?/2` locally. Mailbox overflow protection skips slow subscribers.

## Policy

`Noxir.Policy` behaviour with `Noxir.Policy.Default` (backed by `:persistent_term`). Controls auth requirements, event classification, and REQ validation. Host apps can provide custom impls.

## Distribution

`Noxir.Distribution` behaviour with `Noxir.Distribution.Local` (no-op default). Host provides PubSub impl for multi-node fan-out.

## Supervision

`Noxir.Supervisor` uses `:rest_for_one`: if the SubscriptionRegistry dies, the Store and Bandit restart (connections lose subscriptions). If the Store dies, Bandit restarts. If Bandit dies, storage and registry survive.

# External Dependencies

## Core
- **NostrCore** — Nostr protocol (events, filters, messages, crypto)
- **Bandit** + **Thousand Island** — HTTP/WebSocket server
- **Plug** + **WebSock** + **WebSockAdapter** — web abstractions
- **lib_secp256k1** — Schnorr signature verification (via NostrCore)

## Optional (storage)
- **Memento** — Mnesia wrapper (Mnesia impl)
- **Ecto SQL** + **Postgrex** — Postgres impl

## Dev
- **Credo** — static analysis
- **Dialyxir** — type checking
- **ExDoc** — documentation

# Configuration

Environment variables: `RELAY_NAME`, `RELAY_DESC`, `OWNER_PUBKEY`, `OWNER_CONTACT`, `AUTH_REQUIRED`, `ALLOWED_PUBKEYS`, `PORT`.

See README.md for full configuration reference.
