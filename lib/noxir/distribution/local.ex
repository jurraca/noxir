defmodule Noxir.Distribution.Local do
  @moduledoc """
  Default `Noxir.Distribution` implementation. A no-op: events are
  dispatched locally by `Noxir.SubscriptionRegistry` and nothing is
  forwarded between nodes.
  """

  @behaviour Noxir.Distribution

  @impl true
  def broadcast(_event), do: :ok
end
