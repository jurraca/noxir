defmodule Noxir.Distribution do
  @moduledoc """
  Behaviour for multi-node event distribution.

  Default impl `Noxir.Distribution.Local` is a no-op (single-node). Host apps
  provide a PubSub-based impl to fan out inserts across a cluster. On the
  receiving node, the host calls `Noxir.SubscriptionRegistry.dispatch/2` to
  deliver to local subscribers.
  """

  alias NostrCore.Event

  @doc "Broadcast an event to other nodes in the cluster."
  @callback broadcast(event :: Event.t()) :: :ok

  @doc "Returns the configured distribution implementation module."
  def impl, do: Application.get_env(:noxir, :distribution, Noxir.Distribution.Local)
end
