defmodule Noxir.Policy do
  @moduledoc """
  Relay policy behaviour.

  Controls authentication requirements, event acceptance, and subscription
  policy. The host app can provide a custom impl via `config :noxir, :policy`.
  """

  alias NostrCore.{Event, Filter}

  @doc "Initialize policy state (called at application start)."
  @callback init(opts :: keyword()) :: :ok

  @doc "Whether NIP-42 AUTH is required before EVENT/REQ."
  @callback auth_required?() :: boolean()

  @doc "Whether a pubkey is allowed to post/subscribe."
  @callback allowed_pubkey?(pubkey :: binary()) :: boolean()

  @doc "Returns the list of index keys that subscriptions must include (empty = no requirement)."
  @callback index_keys_required?() :: [atom()]

  @doc """
  Classify an incoming event.

  * `:store` — persist via Store.insert
  * `:ephemeral` — accept but don't store (NIP-16 ephemeral, NIP-42 AUTH)
  * `{:reject, reason}` — reject with OK message
  """
  @callback classify_event(event :: Event.t()) ::
              :store | :ephemeral | {:reject, reason :: binary()}

  @doc "Check whether a REQ is allowed. Returns `:ok` or `{:error, message}`."
  @callback allow_req?(filters :: [Filter.t()], authenticated_pubkey :: binary() | nil) ::
              :ok | {:error, binary()}

  @doc "Returns the configured policy implementation module."
  def impl, do: Application.get_env(:noxir, :policy, Noxir.Policy.Default)
end
