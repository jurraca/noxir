# Start the relay tree explicitly (registry + ETS store, no Bandit/port binding).
# The :noxir application itself boots an empty supervisor in this environment —
# `config :noxir, :standalone` is not set for :test (see config/runtime.exs).
{:ok, _} = Noxir.Supervisor.start_link(start_bandit: false)

ExUnit.start()
