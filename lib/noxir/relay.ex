defmodule Noxir.Relay do
  @moduledoc """
  Nostr Relay message handler.
  """

  @behaviour WebSock

  alias Noxir.Store
  alias Noxir.EventValidator
  alias Store.Connection
  alias Store.Event
  alias Store.Filter

  require Logger

  @impl WebSock
  def init(options) do
    pid = self()

    Memento.transaction!(fn ->
      Connection.open(pid)
    end)

    Process.send_after(pid, :ping, 30_000)

    {:ok, options}
  end

  @impl WebSock
  def handle_in({data, opcode: opcode}, state) do
    case Jason.decode(data) do
      {:ok, ["EVENT", %{"id" => id} = event]} ->
        with true <- valid?(event),
          :ok <- check_auth(event["pubkey"]) do

          event
          |> handle_nostr_event()
          |> resp_nostr_ok(id, opcode, state)

        else
          false ->
            resp_nostr_notice("Invalid message", opcode, state)

          {:error, :auth_required} ->
            send_auth_challenge(opcode, state)

          {:error, :not_authorized} ->
            resp_nostr_ok({:error, "blocked: not authorized"}, id, opcode, state)
        end

      {:ok, ["REQ", subscription_id | filters]} ->
        case get_authenticated_pubkey() do
          nil ->
            send_auth_challenge(opcode, state)

          :ok ->
            case handle_nostr_req(subscription_id, filters) do
              {:error, :no_authors} ->
                resp_nostr_notice(
                  "rejected: this relay requires an 'authors' filter for all subscriptions",
                  opcode,
                  state
                )

              result ->
                resp_nostr_event_and_eose(result, opcode, state)
            end

          {:error, :not_authorized} ->
            resp_nostr_notice("blocked: not authorized", opcode, state)
        end

      {:ok, ["CLOSE", subscription_id]} ->
        handle_nostr_close(subscription_id)
        resp_nostr_notice("Closed sub_id: `#{subscription_id}`", opcode, state)

      {:ok, ["AUTH", %{"kind" => 22242} = auth_event]} ->
        auth_event
        |> handle_nostr_auth()
        |> resp_nostr_ok(Map.get(auth_event, "id", ""), opcode, state)

      _ ->
        resp_nostr_notice("Invalid message", opcode, state)
    end
  end

  @impl WebSock
  def handle_info(:ping, state) do
    Process.send_after(self(), :ping, 50_000)

    {:push, {:ping, ""}, state}
  end

  def handle_info({:create_event, %Event{} = event}, state) do
    msgs =
      fn ->
        Connection.get_subscriptions(self())
      end
      |> Memento.transaction!()
      |> Enum.filter(fn {_, filters} ->
        Filter.match?(filters, event)
      end)
      |> Enum.map(fn {sub_id, _} ->
        msg =
          event
          |> Store.to_map()
          |> resp_nostr_event_msg(sub_id)

        {:text, msg}
      end)

    {:push, msgs, state}
  end

  @impl WebSock
  def terminate(_, state) do
    Memento.transaction!(fn ->
      Connection.disconnect(self())
    end)

    Noxir.SubscriptionIndex.unregister_all(self())

    {:ok, state}
  end

  defp handle_nostr_event(%{"kind" => kind} = event)
       when kind == 1 or (1000 <= kind and kind < 10_000),
       do: handle_nostr_event(event, :regular)

  defp handle_nostr_event(%{"kind" => kind} = event)
       when kind == 0 or kind == 3 or (10_000 <= kind and kind < 20_000),
       do: handle_nostr_event(event, :replaceable)

  defp handle_nostr_event(%{"kind" => 22242} = _event),
    do: {:error, "AUTH events are not stored"}

  defp handle_nostr_event(%{"kind" => kind} = event) when 20_000 <= kind and kind < 30_000,
    do: handle_nostr_event(event, :ephemeral)

  defp handle_nostr_event(%{"kind" => kind} = event) when 30_000 <= kind and kind < 40_000,
    do: handle_nostr_event(event, :parameterized)

  defp handle_nostr_event(event, type \\ :unknown) do
    case EventValidator.validate(event) do
      {:ok, validated_event} ->
        case type do
          :regular -> store_event(validated_event)
          t when t in [:replaceable, :parameterized] -> replace_event(validated_event, t)
          :ephemeral -> {:ok, ""}
          :unknown -> store_event(validated_event)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_event(event) do
    case Store.create_event(event) do
      {:ok, _} ->
        {:ok, ""}

      {:error, reason} ->
        Logger.debug(reason)
        {:error, "Something went wrong"}
    end
  end

  defp replace_event(event, :replaceable) do
    case Store.replace_event(event) do
      {:ok, _} ->
        {:ok, ""}

      {:error, reason} ->
        Logger.debug(reason)
        {:error, "Something went wrong"}
    end
  end

  defp replace_event(event, :parameterized) do
    case Store.replace_event(event, :parameterized) do
      {:ok, _} ->
        {:ok, ""}

      {:error, reason} ->
        Logger.debug(reason)
        {:error, "Something went wrong"}
    end
  end

  defp resp_nostr_ok(res, id, opcode, state) do
    {:push, {opcode, resp_nostr_ok_msg(res, id)}, state}
  end

  defp valid?(%{} = event) do
    valid_id?(event) and valid_sig?(event)
  end

  defp valid_id?(%{"id" => id} = event) do
    compute_id(event) == id
  end

  defp valid_sig?(%{"id" => id, "sig" => sig, "pubkey" => pubkey}) do
    Secp256k1.schnorr_valid?(
      Base.decode16!(sig, case: :lower),
      Base.decode16!(id, case: :lower),
      Base.decode16!(pubkey, case: :lower)
    )
  end

  @spec compute_id(event :: map()) :: binary()
  defp compute_id(%{} = event) do
    :sha256
    |> :crypto.hash(serialize(event))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Serialize event into Nostr ID format
  """
  @spec serialize(event :: map()) :: String.t()
  def serialize(%{
        "pubkey" => pubkey,
        "kind" => kind,
        "tags" => tags,
        "created_at" => created_at,
        "content" => content
      }) do
    Jason.encode!([0, pubkey, created_at, kind, tags, content])
  end

  defp handle_nostr_req(sub_id, filters) do
    if filters_have_authors?(filters) do
      Memento.transaction!(fn ->
        Connection.subscribe(self(), sub_id, filters)
      end)

      Noxir.SubscriptionIndex.register(self(), sub_id, filters)

      case Memento.transaction(fn ->
             Event.req(filters)
           end) do
        {:ok, data} ->
          {sub_id, data}

        {:error, reason} ->
          Logger.debug(reason)
          {sub_id, []}
      end
    else
      {:error, :no_authors}
    end
  end

  defp filters_have_authors?([]), do: false

  defp filters_have_authors?(filters) do
    Enum.all?(filters, fn filter ->
      case Map.get(filter, "authors") do
        [] -> false
        authors when is_list(authors) -> true
        _ -> false
      end
    end)
  end

  defp resp_nostr_event_and_eose({sub_id, events}, opcode, state) do
    evt_msgs =
      events
      |> Enum.map(fn event ->
        event
        |> Store.to_map()
        |> resp_nostr_event_msg(sub_id)
      end)
      |> Enum.reverse()

    msgs =
      [resp_nostr_eose_msg(sub_id) | evt_msgs]
      |> Enum.map(fn msg -> {opcode, msg} end)
      |> Enum.reverse()

    {:push, msgs, state}
  end

  defp handle_nostr_close(sub_id) do
    Memento.transaction!(fn ->
      Connection.close(self(), sub_id)
    end)

    Noxir.SubscriptionIndex.unregister(self(), sub_id)
  end

  defp resp_nostr_notice(msg, opcode, state) do
    {:push, {opcode, resp_nostr_event_msg(msg)}, state}
  end

  defp resp_nostr_event_msg(event, sub_id), do: Jason.encode!(["EVENT", sub_id, event])

  defp resp_nostr_ok_msg({:ok, msg}, id), do: Jason.encode!(["OK", id, true, msg])
  defp resp_nostr_ok_msg({:error, msg}, id), do: Jason.encode!(["OK", id, false, msg])

  defp resp_nostr_eose_msg(sub_id), do: Jason.encode!(["EOSE", sub_id])

  defp resp_nostr_event_msg(msg), do: Jason.encode!(["NOTICE", msg])

  defp handle_nostr_auth(%{"kind" => 22242, "tags" => tags, "pubkey" => pubkey} = auth_event) do
    with {:ok, _} <- EventValidator.validate(auth_event),
         true <- Noxir.AuthConfig.allowed_pubkey?(pubkey),
         challenge = Memento.transaction!(fn -> Connection.get_auth_challenge(self()) end),
         true <- validate_auth_event(tags, challenge) do
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

  defp handle_nostr_auth(_), do: {:error, "invalid: AUTH event must be kind 22242"}

  defp validate_auth_event(tags, challenge) do
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

  defp check_auth(pubkey) do
    auth_required = Noxir.AuthConfig.auth_required?()

    if not auth_required do
      :ok
    else
      Noxir.AuthConfig.allowed_pubkey?(pubkey)
    end
  end

  defp get_authenticated_pubkey do
    # Check if connection is authenticated by looking for stored pubkey
    case Memento.transaction(fn ->
           Connection.get_authenticated_pubkey(self())
         end) do
      {:ok, pubkey} -> pubkey
      _ -> nil
    end
  end

  defp send_auth_challenge(opcode, state) do
    challenge = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    Memento.transaction!(fn ->
      Connection.set_auth_challenge(self(), challenge)
    end)

    msg = Jason.encode!(["AUTH", challenge])
    {:push, {opcode, msg}, state}
  end
end
