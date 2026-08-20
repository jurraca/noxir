defmodule Noxir.Relay.Socket do
  @moduledoc """
  Nostr relay WebSocket handler.

  Parses NIP-01 wire messages via `NostrCore.Message`, delegates validation to
  `NostrCore.Event.validate/1`, persists via `Noxir.Store`, fans out via
  `Noxir.SubscriptionRegistry`, and enforces policy via `Noxir.Policy`.

  Per-connection state holds the NIP-42 auth challenge and authenticated pubkey
  (ephemeral — not persisted to storage).
  """

  @behaviour WebSock

  alias NostrCore.{Event, Filter, Message, Tag}
  alias Noxir.{Policy, Store, SubscriptionRegistry}

  require Logger

  @ping_interval 50_000
  @first_ping 30_000

  defp max_subscriptions do
    Application.get_env(:noxir, :max_subscriptions_per_connection, 100)
  end

  defp max_events_per_minute do
    Application.get_env(:noxir, :max_events_per_minute, 1_000)
  end

  @impl WebSock
  def init(opts) do
    Process.send_after(self(), :ping, @first_ping)

    {:ok,
     %{
       auth_challenge: nil,
       authenticated_pubkey: nil,
       subscriptions: %{},
       rate_tokens: max_events_per_minute() * 1.0,
       rate_last_refill: System.monotonic_time(:millisecond),
       opts: opts
     }}
  end

  @impl WebSock
  def handle_in({data, opcode: opcode}, state) do
    case Message.parse(data) do
      {:ok, {:event, event}} ->
        handle_event(event, opcode, state)

      {:ok, {:req, sub_id, filters}} ->
        handle_req(sub_id, filters, opcode, state)

      {:ok, {:close, sub_id}} ->
        handle_close(sub_id, opcode, state)

      {:ok, {:auth, %Event{kind: 22_242} = auth_event}} ->
        handle_auth(auth_event, opcode, state)

      {:ok, _other} ->
        push_notice("Invalid message", opcode, state)

      {:error, _reason} ->
        push_notice("Invalid message", opcode, state)
    end
  end

  @impl WebSock
  def handle_info(:ping, state) do
    Process.send_after(self(), :ping, @ping_interval)
    {:push, {:ping, ""}, state}
  end

  def handle_info({:event, %Event{} = event}, state) do
    msgs =
      state.subscriptions
      |> Enum.filter(fn {_sub_id, filters} -> Noxir.Filter.match?(filters, event) end)
      |> Enum.map(fn {sub_id, _filters} ->
        {:text, Message.serialize(Message.event(event, sub_id))}
      end)

    if msgs == [] do
      {:ok, state}
    else
      {:push, msgs, state}
    end
  end

  @impl WebSock
  def terminate(_reason, _state) do
    SubscriptionRegistry.unregister_all(self())
    :ok
  end

  # ── EVENT ───────────────────────────────────────────────

  defp handle_event(%Event{} = event, opcode, state) do
    case check_rate_limit(state) do
      {:ok, state} ->
        do_handle_event(event, opcode, state)

      {:rate_limited, state} ->
        push_ok(event.id, false, "rate-limited: slow down", opcode, state)
    end
  end

  defp do_handle_event(%Event{} = event, opcode, state) do
    with :ok <- Event.validate(event),
         :ok <- check_auth(event.pubkey, state),
         action <- Policy.impl().classify_event(event) do
      case action do
        :store ->
          handle_nip09_deletion(event)
          store_and_dispatch(event, opcode, state)

        :ephemeral ->
          push_ok(event.id, true, "", opcode, state)

        {:reject, reason} ->
          push_ok(event.id, false, reason, opcode, state)
      end
    else
      {:error, :auth_required} ->
        send_auth_challenge(opcode, state)

      {:error, :not_authorized} ->
        push_ok(event.id, false, "blocked: not authorized", opcode, state)

      {:error, reason} ->
        push_ok(event.id, false, "invalid: #{reason}", opcode, state)
    end
  end

  defp handle_event(_event, opcode, state) do
    push_notice("Invalid message", opcode, state)
  end

  defp check_rate_limit(state) do
    max = max_events_per_minute()

    if max == 0 do
      {:ok, state}
    else
      now = System.monotonic_time(:millisecond)
      elapsed = now - state.rate_last_refill
      refill = elapsed / 60_000.0 * max
      tokens = min(state.rate_tokens + refill, max * 1.0)

      if tokens >= 1.0 do
        {:ok, %{state | rate_tokens: tokens - 1.0, rate_last_refill: now}}
      else
        {:rate_limited, %{state | rate_tokens: tokens, rate_last_refill: now}}
      end
    end
  end

  defp check_auth(pubkey, state) do
    cond do
      Policy.impl().auth_required?() and state.authenticated_pubkey != pubkey ->
        if Policy.impl().allowed_pubkey?(pubkey),
          do: {:error, :auth_required},
          else: {:error, :not_authorized}

      not Policy.impl().allowed_pubkey?(pubkey) ->
        {:error, :not_authorized}

      true ->
        :ok
    end
  end

  defp store_and_dispatch(event, opcode, state) do
    case Store.impl().insert(event) do
      {:ok, event} ->
        SubscriptionRegistry.dispatch(event, self())
        Noxir.Distribution.impl().broadcast(event)
        push_ok(event.id, true, "", opcode, state)

      {:error, reason} ->
        Logger.warning("store insert failed: #{inspect(reason)}",
          event_id: event.id
        )

        push_ok(event.id, false, "error: could not store event", opcode, state)
    end
  end

  defp handle_nip09_deletion(%Event{kind: 5, pubkey: deleter_pubkey, tags: tags}) do
    Enum.each(tags, fn
      %Tag{type: "e", data: event_id} when is_binary(event_id) ->
        delete_if_owned(event_id, deleter_pubkey)

      %Tag{type: "a", data: addr} when is_binary(addr) ->
        delete_parameterized_if_owned(addr, deleter_pubkey)

      _ ->
        :ok
    end)
  end

  defp handle_nip09_deletion(_), do: :ok

  defp delete_if_owned(event_id, deleter_pubkey) do
    case Store.impl().get(event_id) do
      %Event{pubkey: ^deleter_pubkey} -> Store.impl().delete(event_id)
      _ -> :ok
    end
  end

  defp delete_parameterized_if_owned(addr, deleter_pubkey) do
    case String.split(addr, ":", parts: 3) do
      [pubkey, kind, d_tag] ->
        if pubkey == deleter_pubkey do
          filter = %Filter{
            authors: [pubkey],
            kinds: [String.to_integer(kind)],
            tags: %{"#d" => [d_tag]}
          }

          Enum.each(Store.impl().query([filter]), fn event ->
            Store.impl().delete(event.id)
          end)
        end

      _ ->
        :ok
    end
  end

  # ── REQ ─────────────────────────────────────────────────

  defp handle_req(sub_id, filters, opcode, state) do
    cond do
      Policy.impl().auth_required?() and state.authenticated_pubkey == nil ->
        send_auth_challenge(opcode, state)

      map_size(state.subscriptions) >= max_subscriptions() ->
        push_notice("rejected: too many subscriptions", opcode, state)

      true ->
        case Policy.impl().allow_req?(filters, state.authenticated_pubkey) do
          :ok ->
            accept_req(sub_id, filters, opcode, state)

          {:error, message} ->
            push_notice(message, opcode, state)
        end
    end
  end

  defp accept_req(sub_id, filters, opcode, state) do
    SubscriptionRegistry.register(self(), sub_id, filters)

    events = Store.impl().query(filters)

    msgs =
      (Enum.map(events, fn event ->
         {:text, Message.serialize(Message.event(event, sub_id))}
       end) ++
        [{:text, Message.serialize(Message.eose(sub_id))}])

    new_state = Map.put(state, :subscriptions, Map.put(state.subscriptions, sub_id, filters))
    {:push, msgs, new_state}
  end

  # ── CLOSE ───────────────────────────────────────────────

  defp handle_close(sub_id, opcode, state) do
    SubscriptionRegistry.unregister(self(), sub_id)
    new_state = Map.put(state, :subscriptions, Map.delete(state.subscriptions, sub_id))
    push_notice("Closed sub_id: `#{sub_id}`", opcode, new_state)
  end

  # ── AUTH (NIP-42) ───────────────────────────────────────

  defp handle_auth(%Event{} = auth_event, opcode, state) do
    with :ok <- Event.validate(auth_event),
         true <- Policy.impl().allowed_pubkey?(auth_event.pubkey),
         true <- validate_auth_challenge(auth_event, state.auth_challenge) do
      new_state = %{state | authenticated_pubkey: auth_event.pubkey, auth_challenge: nil}
      push_ok(auth_event.id, true, "", opcode, new_state)
    else
      {:error, reason} ->
        push_ok(Map.get(auth_event, :id, ""), false, "invalid: #{reason}", opcode, state)

      false ->
        push_ok(auth_event.id, false, "invalid: auth event validation failed", opcode, state)
    end
  end

  defp validate_auth_challenge(%Event{tags: tags}, challenge) when is_binary(challenge) do
    has_challenge_tag =
      Enum.any?(tags, fn
        %Tag{type: "challenge", data: ^challenge} -> true
        _ -> false
      end)

    has_relay_tag =
      Enum.any?(tags, fn
        %Tag{type: "relay"} -> true
        _ -> false
      end)

    has_challenge_tag and has_relay_tag
  end

  defp validate_auth_challenge(_event, _challenge), do: false

  defp send_auth_challenge(opcode, state) do
    challenge = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    msg = Message.serialize(Message.auth(challenge))
    {:push, {opcode, msg}, %{state | auth_challenge: challenge}}
  end

  # ── Response helpers ────────────────────────────────────

  defp push_ok(id, success, message, opcode, state) do
    {:push, {opcode, Message.serialize(Message.ok(id, success, message))}, state}
  end

  defp push_notice(message, opcode, state) do
    {:push, {opcode, Message.serialize(Message.notice(message))}, state}
  end
end
