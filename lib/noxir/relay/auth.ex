defmodule Noxir.Relay.Auth do
  @moduledoc """
  Handles NIP-42 authentication for Nostr relay connections.
  """

  alias Noxir.Store.Connection
  alias Noxir.EventValidator
  alias Noxir.AuthConfig

  @spec check() :: :ok | {:error, :auth_required | :not_authorized}
  def check do
    if not AuthConfig.auth_required?() do
      :ok
    else
      case get_pubkey() do
        nil ->
          {:error, :auth_required}

        pubkey ->
          if AuthConfig.allowed_pubkey?(pubkey) do
            :ok
          else
            {:error, :not_authorized}
          end
      end
    end
  end

  @spec get_pubkey() :: binary() | nil
  def get_pubkey do
    case Memento.transaction(fn ->
           Connection.get_authenticated_pubkey(self())
         end) do
      {:ok, pubkey} -> pubkey
      _ -> nil
    end
  end

  @spec verify(map()) :: {:ok, binary()} | {:error, binary()}
  def verify(%{"kind" => 22242, "tags" => tags, "pubkey" => pubkey} = auth_event) do
    with {:ok, _} <- EventValidator.validate(auth_event),
         true <- AuthConfig.allowed_pubkey?(pubkey),
         challenge = Memento.transaction!(fn -> Connection.get_auth_challenge(self()) end),
         true <- validate_auth_tags(tags, challenge) do
      Memento.transaction!(fn ->
        Connection.clear_auth_challenge(self())
        Connection.set_authenticated_pubkey(self(), pubkey)
      end)

      {:ok, ""}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, "invalid: auth event validation failed"}
    end
  end

  def verify(_), do: {:error, "invalid: AUTH event must be kind 22242"}

  @spec send_challenge(atom(), map()) :: {:push, {atom(), binary()}, map()}
  def send_challenge(opcode, state) do
    challenge = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    Memento.transaction!(fn ->
      Connection.set_auth_challenge(self(), challenge)
    end)

    msg = Jason.encode!(["AUTH", challenge])
    {:push, {opcode, msg}, state}
  end

  defp validate_auth_tags(tags, challenge) do
    has_challenge_tag =
      Enum.any?(tags, fn
        ["challenge", ^challenge | _] -> true
        _ -> false
      end)

    has_relay_tag =
      Enum.any?(tags, fn
        ["relay", _relay_url | _] -> true
        _ -> false
      end)

    has_challenge_tag and has_relay_tag
  end
end
