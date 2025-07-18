# Overview

Noxir is a Nostr relay implementation written in Elixir that uses Mnesia as its database backend. Nostr (Notes and Other Stuff Transmitted by Relays) is a decentralized protocol for social networking and content distribution. This relay server handles WebSocket connections from Nostr clients, stores and retrieves events, and provides real-time message delivery according to the Nostr protocol specification.

The application is built using modern Elixir web infrastructure, leveraging Bandit as the HTTP/WebSocket server (instead of the more traditional Cowboy), and Mnesia for distributed, in-memory data storage with optional disk persistence.

# User Preferences

Preferred communication style: Simple, everyday language.

# System Architecture

## Web Server Architecture

**Problem**: Need a high-performance HTTP and WebSocket server to handle Nostr relay connections.

**Solution**: Uses Bandit as the web server, which is a pure Elixir implementation built on Thousand Island. Bandit handles both HTTP requests (for relay information) and WebSocket upgrades (for Nostr protocol communication).

**Rationale**: Bandit provides excellent performance for WebSocket-heavy applications, has native Elixir integration, and supports HTTP/2. It's a modern alternative to Cowboy with cleaner integration into the Elixir ecosystem.

**Key Components**:
- `Noxir.Router` - Main Plug-based router that handles HTTP requests and WebSocket upgrades
- WebSocket handler for Nostr protocol communication
- CORS support via `CorsPlug` for browser-based clients

## Database Architecture

**Problem**: Need persistent, distributed storage for Nostr events that can handle concurrent reads/writes.

**Solution**: Uses Mnesia, Erlang's built-in distributed database system.

**Rationale**: Mnesia provides:
- Native Erlang/Elixir integration with zero external dependencies
- In-memory storage with optional disk persistence
- Built-in distribution and replication across nodes
- ACID transaction support
- Real-time querying capabilities

**Trade-offs**: Mnesia is excellent for Erlang/Elixir applications but has different scaling characteristics than traditional databases like PostgreSQL. It's optimized for scenarios where the entire dataset can fit in memory.

## Cryptographic Architecture

**Problem**: Nostr protocol requires secp256k1 elliptic curve cryptography for signature verification.

**Solution**: Uses `lib_secp256k1` library which provides Elixir NIF bindings to the Bitcoin Core secp256k1 C library.

**Rationale**: The secp256k1 C library is battle-tested, highly optimized, and the de facto standard for this cryptographic curve. Using NIFs provides native performance for signature verification operations.

## Configuration Architecture

**Problem**: Need flexible configuration for relay metadata and network settings.

**Solution**: Uses environment variables for runtime configuration:
- `RELAY_NAME` - Relay information name
- `RELAY_DESC` - Relay description
- `OWNER_PUBKEY` - Owner's public key (hex format)
- `OWNER_CONTACT` - Contact information URI

**Rationale**: Environment variables allow easy configuration in containerized deployments without code changes.

## Deployment Architecture

**Problem**: Need to support both local development and production deployments, with optional horizontal scaling.

**Solution**: Supports multiple deployment strategies:
1. Local development via `mix run`
2. Docker Compose with configurable replica count
3. Build from source for custom deployments

**Rationale**: Docker Compose allows easy horizontal scaling via the `deploy.replicas` setting, while maintaining simple local development workflows.

## Event Broadcasting Architecture

**Problem**: When a new event arrives, the relay needs to notify all subscribers whose filters match. The naive approach of broadcasting to all connections and filtering locally creates O(n) message overhead and a thundering herd of Mnesia reads.

**Solution**: Uses OTP's `pg` (process groups) for targeted event routing:
- `Noxir.SubscriptionIndex` - Manages pg groups keyed by author pubkeys. Connections join `{:author, pubkey}` groups based on their subscription filters.
- `Noxir.Broadcaster` - Dedicated GenServer that handles event fan-out, keeping the Store out of the broadcast hot path.

**Flow**:
1. Client sends REQ → Relay registers with SubscriptionIndex (joins author groups)
2. Event arrives → Store persists → casts to Broadcaster
3. Broadcaster queries SubscriptionIndex for candidates (pids subscribed to event's author)
4. Only candidate pids receive the event → each runs `Filter.match?/2` locally for final confirmation

**Design Decisions**:
- Index only by author pubkeys (most selective dimension)
- Authorless filters are rejected with a NOTICE - this is intentional relay policy to prevent spam
- ETS-backed refcounting handles overlapping subscriptions from the same connection
- pg automatically cleans up when connection processes die
- Subscription ID reuse is handled by unregistering old filters before registering new ones
- NIP-11 advertises `limitation.authors_required = true` so clients know the policy upfront

**Rationale**: This balances efficiency with OTP idioms. The pg module is battle-tested, cluster-aware, and provides O(1) group membership lookups. Each Relay process still owns its filter matching logic, keeping work distributed.

## Authentication & Authorization Architecture

**Problem**: Need to control which pubkeys can post to the relay, with the ability to update the allowlist at runtime without restarting the application.

**Solution**: Uses `:persistent_term` for runtime-updatable configuration:
- `Noxir.AuthConfig` - Manages auth settings with `:persistent_term` storage for fast reads
- Initial config loaded from Application env on startup (`Noxir.AuthConfig.init/0`)
- Runtime update functions: `add_pubkey/1`, `remove_pubkey/1`, `set_pubkeys/1`, `clear_pubkeys/0`

**Configuration**:
```elixir
config :noxir, :auth,
  required: true,
  allowed_pubkeys: ["pubkey1_hex", "pubkey2_hex"]
```

**Behavior**:
- When `required: true`, clients must complete NIP-42 AUTH handshake
- If `allowed_pubkeys` is empty, all authenticated pubkeys are allowed
- If `allowed_pubkeys` has entries, only those pubkeys can post/subscribe
- Pubkey checks happen on every EVENT and REQ, not just during AUTH

**Rationale**: `:persistent_term` provides extremely fast reads (no process lookup) which is important since the check happens on every message. Updates are infrequent (admin actions) so the update cost is acceptable.

## JSON Serialization

**Problem**: Nostr protocol uses JSON for all message formats.

**Solution**: Uses Jason as the JSON encoder/decoder.

**Rationale**: Jason is the fastest and most widely-used JSON library in the Elixir ecosystem, with better performance than alternatives like Poison.

# External Dependencies

## Core Infrastructure
- **Bandit** (~> 1.5) - HTTP/1.x, HTTP/2, and WebSocket server built on Thousand Island
- **Thousand Island** - Low-level socket server framework (transitive dependency via Bandit)
- **Plug** (~> 1.16) - Composable web application specification and connection handling
- **WebSock** & **WebSockAdapter** - WebSocket specification and adapters for Plug

## Database
- **Mnesia** - Built-in Erlang distributed database (no external dependency - part of Erlang/OTP)
- **Memento** - Elixir-friendly wrapper around Mnesia providing simpler APIs

## Cryptography
- **lib_secp256k1** - Elixir NIF bindings to Bitcoin Core's secp256k1 library for ECDSA operations
- **Plug.Crypto** - Cryptographic functions for Plug (transitive)

## Data Serialization
- **Jason** - Fast JSON encoder/decoder for Nostr message handling

## Utilities
- **CorsPlug** - Cross-Origin Resource Sharing (CORS) middleware for browser client support
- **MIME** - MIME type handling

## Development/Build Tools
- **Credo** - Static code analysis (dev/test only)
- **Dialyxir** - Dialyzer integration for type checking (dev/test only)
- **ExDoc** - Documentation generation (dev/test only)
- **Elixir Make** - Make compiler integration for building C dependencies
- Various supporting libraries for documentation and formatting

## Container Deployment
- Docker Compose for orchestration with configurable scaling