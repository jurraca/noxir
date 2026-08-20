defmodule Noxir.Store do
  @moduledoc """
  Behaviour for Nostr event storage backends.

  Each implementation owns persistence, indexing, and replaceable/parameterized
  event semantics. Implementations provide a `child_spec/1` for supervision and
  expose the functional callbacks below. Calls happen in the caller's process —
  no centralized GenServer serialization.
  """

  alias NostrCore.{Event, Filter}

  @doc "Supervision child spec for table/schema ownership."
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()

  @doc """
  Insert a validated event.

  Replaceable (kind 0, 3, 10000–19999) and parameterized replaceable
  (30000–39999) semantics are handled internally — the impl deletes older
  versions with the same pubkey/kind (and `d` tag for parameterized) as needed.
  """
  @callback insert(event :: Event.t()) :: {:ok, Event.t()} | {:error, term()}

  @doc "Query events matching any of the given filters. Results deduplicated, newest first."
  @callback query(filters :: [Filter.t()]) :: [Event.t()]

  @doc "Fetch a single event by ID. Returns `nil` if not found."
  @callback get(event_id :: binary()) :: Event.t() | nil

  @doc "Delete an event by ID (NIP-09)."
  @callback delete(event_id :: binary()) :: :ok | {:error, term()}

  @doc "Count events matching any of the given filters."
  @callback count(filters :: [Filter.t()]) :: non_neg_integer()

  @doc "Returns the configured store implementation module."
  def impl, do: Application.get_env(:noxir, :store, Noxir.Store.ETS)
end
