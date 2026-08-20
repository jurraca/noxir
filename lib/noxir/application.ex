defmodule Noxir.Application do
  @moduledoc """
  Application callback for dual-mode operation.

  In standalone mode (`config :noxir, :standalone, true`), starts the full
  supervision tree via `Noxir.Supervisor` with Bandit.

  When embedded as a dependency, `:standalone` defaults to `false` and this
  callback returns `:ignore` — the app is loaded but owns no processes. The
  host app adds `Noxir.Supervisor` (or granular children) to its own
  supervision tree.
  """

  use Application

  @impl Application
  def start(_, _) do
    if Application.get_env(:noxir, :standalone, false) do
      Noxir.Supervisor.start_link(start_bandit: true)
    else
      :ignore
    end
  end
end
