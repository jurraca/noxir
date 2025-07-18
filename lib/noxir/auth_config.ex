defmodule Noxir.AuthConfig do
  @moduledoc """
  Authentication configuration using :persistent_term for runtime updates.
  
  This module manages the allowlist of pubkeys that are permitted to post
  to the relay. The allowlist can be updated at runtime without recompiling.
  """

  @auth_required_key {__MODULE__, :auth_required}
  @allowed_pubkeys_key {__MODULE__, :allowed_pubkeys}

  @spec init() :: :ok
  def init do
    auth_config = Application.get_env(:noxir, :auth, [])
    auth_required = Keyword.get(auth_config, :required, false)
    allowed_pubkeys = Keyword.get(auth_config, :allowed_pubkeys, [])

    :persistent_term.put(@auth_required_key, auth_required)
    :persistent_term.put(@allowed_pubkeys_key, MapSet.new(allowed_pubkeys))

    :ok
  end

  @spec auth_required?() :: boolean()
  def auth_required? do
    :persistent_term.get(@auth_required_key, false)
  end

  @spec set_auth_required(boolean()) :: :ok
  def set_auth_required(required) when is_boolean(required) do
    :persistent_term.put(@auth_required_key, required)
    :ok
  end

  @spec allowed_pubkey?(binary()) :: boolean()
  def allowed_pubkey?(pubkey) do
    pubkeys = :persistent_term.get(@allowed_pubkeys_key, MapSet.new())
    MapSet.size(pubkeys) == 0 or MapSet.member?(pubkeys, pubkey)
  end

  @spec has_allowed_pubkeys?() :: boolean()
  def has_allowed_pubkeys? do
    pubkeys = :persistent_term.get(@allowed_pubkeys_key, MapSet.new())
    MapSet.size(pubkeys) > 0
  end

  @spec get_allowed_pubkeys() :: [binary()]
  def get_allowed_pubkeys do
    :persistent_term.get(@allowed_pubkeys_key, MapSet.new())
    |> MapSet.to_list()
  end

  @spec set_pubkeys([binary()]) :: :ok
  def set_pubkeys(pubkeys) when is_list(pubkeys) do
    :persistent_term.put(@allowed_pubkeys_key, MapSet.new(pubkeys))
    :ok
  end

  @spec add_pubkey(binary()) :: :ok
  def add_pubkey(pubkey) when is_binary(pubkey) do
    pubkeys = :persistent_term.get(@allowed_pubkeys_key, MapSet.new())
    :persistent_term.put(@allowed_pubkeys_key, MapSet.put(pubkeys, pubkey))
    :ok
  end

  @spec remove_pubkey(binary()) :: :ok
  def remove_pubkey(pubkey) when is_binary(pubkey) do
    pubkeys = :persistent_term.get(@allowed_pubkeys_key, MapSet.new())
    :persistent_term.put(@allowed_pubkeys_key, MapSet.delete(pubkeys, pubkey))
    :ok
  end

  @spec clear_pubkeys() :: :ok
  def clear_pubkeys do
    :persistent_term.put(@allowed_pubkeys_key, MapSet.new())
    :ok
  end
end
