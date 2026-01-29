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
  alias Noxir.EventValidator
  alias Noxir.Relay.Events
  alias Noxir.Relay.Auth

  require Logger

  @impl WebSock
  def init(_options) do
    pid = self()

    Memento.transaction!(fn ->
      Connection.open(pid)
    end)

    Process.send_after(pid, :ping, 30_000)

    {:ok, %{subscriptions: []}}
  end

  @impl WebSock
  def handle_in({data, opcode: opcode}, state) do
    case Jason.decode(data) do
      {:ok, ["EVENT", %{"id" => id} = event]} ->
<<<<<<< HEAD
        with true <- valid?(event),
          :ok <- check_auth(event["pubkey"]) do

          event
          |> handle_nostr_event()
          |> resp_nostr_ok(id, opcode, state)

        else
          false ->
            resp_nostr_notice("Invalid message", opcode, state)
=======
        case Auth.check() do
          :ok ->
            event
            |> handle_nostr_event()
            |> resp_nostr_ok(id, opcode, state)
>>>>>>> 433a131 (Extract authentication logic to a new module)

          {:error, :auth_required} ->
            Auth.send_challenge(opcode, state)

          {:error, :not_authorized} ->
            resp_nostr_ok({:error, "blocked: not authorized"}, id, opcode, state)
        end

      {:ok, ["REQ", subscription_id | filters]} ->
<<<<<<< HEAD
        case get_authenticated_pubkey() do
          nil ->
            send_auth_challenge(opcode, state)

=======
        case Auth.check() do
>>>>>>> 433a131 (Extract authentication logic to a new module)
          :ok ->
            case handle_nostr_req(subscription_id, filters, state) do
              {:error, :no_authors} ->
                resp_nostr_notice(
                  "rejected: this relay requires an 'authors' filter for all subscriptions",
                  opcode,
                  state
                )

              {result, new_state} ->
                resp_nostr_event_and_eose(result, opcode, new_state)
            end

<<<<<<< HEAD
=======
          {:error, :auth_required} ->
            Auth.send_challenge(opcode, state)

>>>>>>> 433a131 (Extract authentication logic to a new module)
          {:error, :not_authorized} ->
            resp_nostr_notice("blocked: not authorized", opcode, state)
        end

      {:ok, ["CLOSE", subscription_id]} ->
        new_state = handle_nostr_close(subscription_id, state)
        resp_nostr_notice("Closed sub_id: `#{subscription_id}`", opcode, new_state)

      {:ok, ["AUTH", %{"kind" => 22242} = auth_event]} ->
        auth_event
        |> Auth.verify()
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

  def handle_info({:event_published, %Event{} = event}, state) do
    msgs =
      state.subscriptions
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
          :regular -> Events.store(validated_event)
          t when t in [:replaceable, :parameterized] -> Events.replace(validated_event, t)
          :ephemeral -> {:ok, ""}
          :unknown -> Events.store(validated_event)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resp_nostr_ok(res, id, opcode, state) do
    {:push, {opcode, resp_nostr_ok_msg(res, id)}, state}
  end

  defp handle_nostr_req(sub_id, filters, state) do
    if filters_have_authors?(filters) do
      # Parse filters into Filter structs for caching
      parsed_filters = Enum.map(filters, &struct(Filter, Store.change_to_existing_atom_key(&1)))

      # Still write to Mnesia for persistence across reconnects
      Memento.transaction!(fn ->
        Connection.subscribe(self(), sub_id, parsed_filters)
      end)

      Noxir.SubscriptionIndex.register(self(), sub_id, filters)

      # Cache subscriptions in state (replace if same sub_id exists)
      new_subscriptions = List.keystore(state.subscriptions, sub_id, 0, {sub_id, parsed_filters})
      new_state = %{state | subscriptions: new_subscriptions}

      case Memento.transaction(fn ->
             Event.req(filters)
           end) do
        {:ok, data} ->
          {{sub_id, data}, new_state}

        {:error, reason} ->
          Logger.debug(reason)
          {{sub_id, []}, new_state}
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

  defp handle_nostr_close(sub_id, state) do
    Memento.transaction!(fn ->
      Connection.close(self(), sub_id)
    end)

    Noxir.SubscriptionIndex.unregister(self(), sub_id)

    # Remove from cached subscriptions
    %{state | subscriptions: List.keydelete(state.subscriptions, sub_id, 0)}
  end

  defp resp_nostr_notice(msg, opcode, state) do
    {:push, {opcode, resp_nostr_event_msg(msg)}, state}
  end

  defp resp_nostr_event_msg(event, sub_id), do: Jason.encode!(["EVENT", sub_id, event])

  defp resp_nostr_ok_msg({:ok, msg}, id), do: Jason.encode!(["OK", id, true, msg])
  defp resp_nostr_ok_msg({:error, msg}, id), do: Jason.encode!(["OK", id, false, msg])

  defp resp_nostr_eose_msg(sub_id), do: Jason.encode!(["EOSE", sub_id])

  defp resp_nostr_event_msg(msg), do: Jason.encode!(["NOTICE", msg])
end
