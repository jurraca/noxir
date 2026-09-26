defmodule Noxir.Test.SQLiteRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :noxir, adapter: Ecto.Adapters.SQLite3
end
