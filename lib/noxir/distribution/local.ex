defmodule Noxir.Distribution.Local do
  @moduledoc false

  @behaviour Noxir.Distribution

  @impl true
  def broadcast(_event), do: :ok
end
