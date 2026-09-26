defmodule Noxir.SupervisorTest do
  use ExUnit.Case, async: false

  alias Noxir.Policy.Default
  alias Noxir.Supervisor

  test "validate_index_config!/1 passes when required keys are routed" do
    Default.init(required: false, allowed_pubkeys: [], index_keys_required: [:authors])
    Application.put_env(:noxir, :subscription_index_keys, [:authors, :"#h"])

    assert :ok = Supervisor.validate_index_config!(Default)
  after
    Application.put_env(:noxir, :subscription_index_keys, [:authors])
  end

  test "validate_index_config!/1 passes when no keys are required" do
    Default.init(required: false, allowed_pubkeys: [], index_keys_required: [])
    Application.put_env(:noxir, :subscription_index_keys, [])

    assert :ok = Supervisor.validate_index_config!(Default)
  after
    Application.put_env(:noxir, :subscription_index_keys, [:authors])
    Default.init(required: false, allowed_pubkeys: [], index_keys_required: [:authors])
  end

  test "validate_index_config!/1 raises when required keys are not routed" do
    Default.init(required: false, allowed_pubkeys: [], index_keys_required: [:authors, :"#h"])
    Application.put_env(:noxir, :subscription_index_keys, [:authors])

    assert_raise ArgumentError, ~r/not in subscription_index_keys/, fn ->
      Supervisor.validate_index_config!(Default)
    end
  after
    Application.put_env(:noxir, :subscription_index_keys, [:authors])
    Default.init(required: false, allowed_pubkeys: [], index_keys_required: [:authors])
  end
end
