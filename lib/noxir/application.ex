defmodule Noxir.Application do
  @moduledoc """
  Application callback for dual-mode operation.

  In standalone mode (`config :noxir, :standalone, true`), starts the full
  supervision tree via `Noxir.Supervisor` with Bandit.

  When embedded as a dependency, `:standalone` defaults to `false` and the
  application starts an empty supervisor — the host app adds `Noxir.Supervisor`
  (or granular children) to its own supervision tree.
  """

  use Application

  @impl Application
  def start(_, _) do
    children =
      if Application.get_env(:noxir, :standalone, false) do
        [{Noxir.Supervisor, start_bandit: true}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Noxir.AppSup)
  end
end
