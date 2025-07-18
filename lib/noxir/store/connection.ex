defmodule Noxir.Store.Connection do
  @moduledoc false

  use Memento.Table,
    attributes: [:pid, :subscriptions, :auth_challenge, :authenticated_pubkey]

  alias Memento.Query
  alias Noxir.Store.Filter

  @spec open(pid()) :: Memento.Table.record() | no_return()
  def open(pid) do
    Query.write(%__MODULE__{
      pid: pid,
      subscriptions: [],
      auth_challenge: nil,
      authenticated_pubkey: nil
    })
  end

  @spec disconnect(pid()) :: :ok
  def disconnect(pid) do
    Query.delete(__MODULE__, pid)
  end

  @spec subscribe(pid(), binary(), [Filter.t() | map()]) :: Memento.Table.record() | no_return()
  def subscribe(pid, sub_id, [%Filter{} | _] = filters) do
    __MODULE__
    |> Query.read(pid)
    |> Map.replace_lazy(:subscriptions, fn subs ->
      List.keystore(subs, sub_id, 0, {sub_id, filters})
    end)
    |> Query.write()
  end

  def subscribe(pid, sub_id, filters) do
    subscribe(
      pid,
      sub_id,
      Enum.map(filters, &struct(Filter, Noxir.Store.change_to_existing_atom_key(&1)))
    )
  end

  @spec close(pid(), binary()) :: Memento.Table.record() | no_return()
  def close(pid, sub_id) do
    __MODULE__
    |> Query.read(pid)
    |> Map.replace_lazy(:subscriptions, fn subs ->
      List.keydelete(subs, sub_id, 0)
    end)
    |> Query.write()
  end

  @spec all :: [Memento.Table.record()]
  def all do
    Query.all(__MODULE__)
  end

  @spec get_subscriptions(pid()) :: [{binary(), [map()]}]
  def get_subscriptions(pid) do
    __MODULE__
    |> Query.read(pid)
    |> Map.get(:subscriptions)
  end

  @spec set_auth_challenge(pid(), binary()) :: Memento.Table.record() | no_return()
  def set_auth_challenge(pid, challenge) do
    __MODULE__
    |> Query.read(pid)
    |> Map.put(:auth_challenge, challenge)
    |> Query.write()
  end

  @spec get_auth_challenge(pid()) :: binary() | nil
  def get_auth_challenge(pid) do
    __MODULE__
    |> Query.read(pid)
    |> Map.get(:auth_challenge)
  end

  @spec clear_auth_challenge(pid()) :: Memento.Table.record() | no_return()
  def clear_auth_challenge(pid) do
    __MODULE__
    |> Query.read(pid)
    |> Map.put(:auth_challenge, nil)
    |> Query.write()
  end

  @spec set_authenticated_pubkey(pid(), binary()) :: Memento.Table.record() | no_return()
  def set_authenticated_pubkey(pid, pubkey) do
    __MODULE__
    |> Query.read(pid)
    |> Map.put(:authenticated_pubkey, pubkey)
    |> Query.write()
  end

  @spec get_authenticated_pubkey(pid()) :: binary() | nil
  def get_authenticated_pubkey(pid) do
    __MODULE__
    |> Query.read(pid)
    |> Map.get(:authenticated_pubkey)
  end
end
