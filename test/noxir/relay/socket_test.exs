defmodule Noxir.Relay.SocketTest do
  use ExUnit.Case, async: false

  alias NostrCore.{Event, Message, Tag}
  alias Noxir.{Policy.Default, Relay.Socket, Store}
  alias Noxir.Test.Fixtures

  setup do
    Application.ensure_all_started(:noxir)
    :ets.delete_all_objects(:noxir_ets_events)
    :ets.delete_all_objects(:noxir_ets_by_author)
    :ets.delete_all_objects(:noxir_ets_tag_index)
    :ok
  end

  describe "init/1" do
    test "returns ok with initial state" do
      assert {:ok, state} = Socket.init([])
      assert state.auth_challenge == nil
      assert state.authenticated_pubkey == nil
      assert state.subscriptions == %{}
    end
  end

  describe "handle_in EVENT" do
    test "valid event is stored and returns OK true" do
      event = Fixtures.signed_event(kind: 1, content: "hello")
      wire = JSON.encode!(["EVENT", event_to_map(event)])

      {:push, {:text, msg}, _state} = Socket.handle_in({wire, opcode: :text}, init_state())
      {:ok, {:ok, id, true, _}} = Message.parse(msg)
      assert id == event.id
    end

    test "invalid event returns OK false" do
      raw = Fixtures.raw_event_map() |> Map.put("sig", String.duplicate("0", 128))
      wire = JSON.encode!(["EVENT", raw])

      {:push, {:text, msg}, _state} = Socket.handle_in({wire, opcode: :text}, init_state())
      {:ok, {:ok, _id, false, _msg}} = Message.parse(msg)
    end

    test "kind 22_242 AUTH event returns OK true but is not stored" do
      event = Fixtures.signed_event(kind: 22_242, content: "auth")
      wire = JSON.encode!(["EVENT", event_to_map(event)])

      {:push, {:text, msg}, _state} = Socket.handle_in({wire, opcode: :text}, init_state())
      {:ok, {:ok, id, true, _}} = Message.parse(msg)
      assert id == event.id

      result = Store.impl().query([%NostrCore.Filter{ids: [event.id]}])
      assert result == []
    end
  end

  describe "handle_in REQ" do
    test "REQ without index keys returns NOTICE" do
      wire = Fixtures.wire_req("sub1", [%{"kinds" => [1]}])

      {:push, {:text, msg}, _state} = Socket.handle_in({wire, opcode: :text}, init_state())
      {:ok, {:notice, message}} = Message.parse(msg)
      assert String.contains?(message, "author")
    end

    test "REQ with authors returns events and EOSE" do
      event = Fixtures.signed_event(kind: 1, content: "hello")
      {:ok, _} = Store.impl().insert(event)

      wire = Fixtures.wire_req("sub1", [%{"authors" => [event.pubkey], "kinds" => [1]}])

      {:push, msgs, _state} = Socket.handle_in({wire, opcode: :text}, init_state())

      parsed = Enum.map(msgs, fn {:text, m} ->
        {:ok, p} = Message.parse(m)
        p
      end)

      event_parsed = Enum.find(parsed, &match?({:event, "sub1", _}, &1))
      assert event_parsed != nil
      assert elem(event_parsed, 2).id == event.id
      assert {:eose, "sub1"} in parsed
    end
  end

  describe "handle_in CLOSE" do
    test "closes a subscription and returns NOTICE" do
      wire = Fixtures.wire_close("sub1")

      {:push, {:text, msg}, _state} =
        Socket.handle_in({wire, opcode: :text}, init_state())

      {:ok, {:notice, message}} = Message.parse(msg)
      assert String.contains?(message, "sub1")
    end
  end

  describe "handle_in REQ subscription cap" do
    test "rejects REQ when per-connection subscription limit is reached" do
      Application.put_env(:noxir, :max_subscriptions_per_connection, 2)

      state = init_state()

      wire1 = Fixtures.wire_req("sub1", [%{"authors" => [Fixtures.pubkey()]}])
      {:push, _, state} = Socket.handle_in({wire1, opcode: :text}, state)

      wire2 = Fixtures.wire_req("sub2", [%{"authors" => [Fixtures.pubkey()]}])
      {:push, _, state} = Socket.handle_in({wire2, opcode: :text}, state)

      wire3 = Fixtures.wire_req("sub3", [%{"authors" => [Fixtures.pubkey()]}])
      {:push, {:text, msg}, _state} = Socket.handle_in({wire3, opcode: :text}, state)

      {:ok, {:notice, message}} = Message.parse(msg)
      assert String.contains?(message, "too many subscriptions")

      Application.put_env(:noxir, :max_subscriptions_per_connection, 100)
    end
  end

  describe "handle_in EVENT rate limiting" do
    test "events within rate limit are accepted" do
      Application.put_env(:noxir, :max_events_per_minute, 10)

      state = init_state()

      event = Fixtures.signed_event(kind: 1, content: "ok")
      wire = JSON.encode!(["EVENT", event_to_map(event)])

      {:push, {:text, msg}, _state} = Socket.handle_in({wire, opcode: :text}, state)
      {:ok, {:ok, id, true, _}} = Message.parse(msg)
      assert id == event.id

      Application.put_env(:noxir, :max_events_per_minute, 1_000)
    end

    test "events exceeding rate limit are rejected" do
      Application.put_env(:noxir, :max_events_per_minute, 2)

      state = init_state()

      {state, _} =
        Enum.reduce(1..2, {state, []}, fn _, {st, _acc} ->
          event = Fixtures.signed_event(kind: 1, content: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
          wire = JSON.encode!(["EVENT", event_to_map(event)])
          {:push, {:text, msg}, new_state} = Socket.handle_in({wire, opcode: :text}, st)
          {:ok, {:ok, _, true, _}} = Message.parse(msg)
          {new_state, []}
        end)

      event3 = Fixtures.signed_event(kind: 1, content: "third")
      wire3 = JSON.encode!(["EVENT", event_to_map(event3)])
      {:push, {:text, msg}, _state} = Socket.handle_in({wire3, opcode: :text}, state)
      {:ok, {:ok, _, false, reason}} = Message.parse(msg)
      assert String.contains?(reason, "rate-limited")

      Application.put_env(:noxir, :max_events_per_minute, 1_000)
    end
  end

  describe "handle_in EVENT NIP-09 deletion" do
    test "kind-5 deletion removes own event" do
      target = Fixtures.signed_event(kind: 1, content: "delete me")
      {:ok, _} = Store.impl().insert(target)

      e_tag = Tag.create!("e", target.id)
      delete_event = Fixtures.signed_event(kind: 5, content: "", tags: [e_tag])
      wire = JSON.encode!(["EVENT", event_to_map(delete_event)])

      {:push, {:text, msg}, _state} = Socket.handle_in({wire, opcode: :text}, init_state())
      {:ok, {:ok, _, true, _}} = Message.parse(msg)

      assert Store.impl().get(target.id) == nil
    end

    test "kind-5 deletion does not remove other pubkey's event" do
      victim = Fixtures.signed_event(kind: 1, content: "victim", seckey: Fixtures.seckey())
      {:ok, _} = Store.impl().insert(victim)

      e_tag = Tag.create!("e", victim.id)
      delete_event = Fixtures.signed_event(kind: 5, content: "", tags: [e_tag], seckey: Fixtures.seckey2())
      wire = JSON.encode!(["EVENT", event_to_map(delete_event)])

      {:push, {:text, msg}, _state} = Socket.handle_in({wire, opcode: :text}, init_state())
      {:ok, {:ok, _, true, _}} = Message.parse(msg)

      assert Store.impl().get(victim.id) != nil
    end

    test "kind-5 deletion with a tag removes own parameterized event" do
      d_tag = Tag.create!("d", "my-article")
      target = Fixtures.signed_event(kind: 30_023, content: "article", tags: [d_tag])
      {:ok, _} = Store.impl().insert(target)

      a_tag = Tag.create!("a", "#{Fixtures.pubkey()}:30023:my-article")
      delete_event = Fixtures.signed_event(kind: 5, content: "", tags: [a_tag])
      wire = JSON.encode!(["EVENT", event_to_map(delete_event)])

      {:push, {:text, msg}, _state} = Socket.handle_in({wire, opcode: :text}, init_state())
      {:ok, {:ok, _, true, _}} = Message.parse(msg)

      assert Store.impl().get(target.id) == nil
    end
  end

  describe "handle_info {:event, event}" do
    test "matching subscription receives EVENT message" do
      event = Fixtures.signed_event(kind: 1, content: "fanout test")
      filters = [%NostrCore.Filter{authors: [event.pubkey], kinds: [1]}]

      state = %{init_state() | subscriptions: %{"sub1" => filters}}

      {:push, msgs, _state} = Socket.handle_info({:event, event}, state)

      [{:text, msg}] = msgs
      {:ok, {:event, "sub1", ^event}} = Message.parse(msg)
    end

    test "no matching subscriptions returns ok without push" do
      event = Fixtures.signed_event(kind: 1)
      state = %{init_state() | subscriptions: %{}}

      assert {:ok, _state} = Socket.handle_info({:event, event}, state)
    end
  end

  describe "handle_in AUTH" do
    test "valid auth event with matching challenge returns OK true" do
      challenge = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

      relay_tag = Tag.create!("relay", "ws://localhost:4400")
      challenge_tag = Tag.create!("challenge", challenge)

      auth_event =
        Fixtures.signed_event(
          kind: 22_242,
          content: "",
          tags: [relay_tag, challenge_tag]
        )

      wire = JSON.encode!(["AUTH", event_to_map(auth_event)])

      state = %{init_state() | auth_challenge: challenge}

      {:push, {:text, msg}, new_state} =
        Socket.handle_in({wire, opcode: :text}, state)

      {:ok, {:ok, id, true, _}} = Message.parse(msg)
      assert id == auth_event.id
      assert new_state.authenticated_pubkey == auth_event.pubkey
      assert new_state.auth_challenge == nil
    end

    test "auth event with wrong challenge returns OK false" do
      relay_tag = Tag.create!("relay", "ws://localhost:4400")
      challenge_tag = Tag.create!("challenge", "wrongchallenge")

      auth_event =
        Fixtures.signed_event(
          kind: 22_242,
          content: "",
          tags: [relay_tag, challenge_tag]
        )

      wire = JSON.encode!(["AUTH", event_to_map(auth_event)])

      state = %{init_state() | auth_challenge: "correctchallenge"}

      {:push, {:text, msg}, _state} =
        Socket.handle_in({wire, opcode: :text}, state)

      {:ok, {:ok, _, false, _}} = Message.parse(msg)
    end
  end

  describe "handle_in with auth_required" do
    setup do
      Default.init(required: true, allowed_pubkeys: [], index_keys_required: [:authors])
      on_exit(fn -> Default.init(required: false, allowed_pubkeys: [], index_keys_required: [:authors]) end)
      :ok
    end

    test "EVENT rejected with AUTH challenge when not authenticated" do
      event = Fixtures.signed_event(kind: 1, content: "hello")
      wire = JSON.encode!(["EVENT", event_to_map(event)])

      {:push, {:text, msg}, new_state} = Socket.handle_in({wire, opcode: :text}, init_state())

      {:ok, {:auth, challenge}} = Message.parse(msg)
      assert is_binary(challenge)
      assert new_state.auth_challenge == challenge
    end

    test "REQ rejected with AUTH challenge when not authenticated" do
      wire = Fixtures.wire_req("sub1", [%{"authors" => [Fixtures.pubkey()]}])

      {:push, {:text, msg}, new_state} = Socket.handle_in({wire, opcode: :text}, init_state())

      {:ok, {:auth, challenge}} = Message.parse(msg)
      assert is_binary(challenge)
      assert new_state.auth_challenge == challenge
    end

    test "EVENT accepted after successful AUTH" do
      state = init_state()

      challenge = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      state = %{state | auth_challenge: challenge}

      relay_tag = Tag.create!("relay", "ws://localhost:4400")
      challenge_tag = Tag.create!("challenge", challenge)

      auth_event =
        Fixtures.signed_event(
          kind: 22_242,
          content: "",
          tags: [relay_tag, challenge_tag]
        )

      auth_wire = JSON.encode!(["AUTH", event_to_map(auth_event)])
      {:push, {:text, msg}, state} = Socket.handle_in({auth_wire, opcode: :text}, state)
      {:ok, {:ok, _, true, _}} = Message.parse(msg)
      assert state.authenticated_pubkey == auth_event.pubkey

      event = Fixtures.signed_event(kind: 1, content: "after auth")
      wire = JSON.encode!(["EVENT", event_to_map(event)])

      {:push, {:text, msg}, _state} = Socket.handle_in({wire, opcode: :text}, state)
      {:ok, {:ok, id, true, _}} = Message.parse(msg)
      assert id == event.id
    end

    test "EVENT from wrong pubkey gets AUTH challenge after AUTH as different pubkey" do
      state = init_state()

      challenge = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      state = %{state | auth_challenge: challenge}

      relay_tag = Tag.create!("relay", "ws://localhost:4400")
      challenge_tag = Tag.create!("challenge", challenge)

      auth_event =
        Fixtures.signed_event(
          kind: 22_242,
          content: "",
          tags: [relay_tag, challenge_tag]
        )

      auth_wire = JSON.encode!(["AUTH", event_to_map(auth_event)])
      {:push, {:text, _msg}, state} = Socket.handle_in({auth_wire, opcode: :text}, state)
      assert state.authenticated_pubkey == auth_event.pubkey

      event_from_other = Fixtures.signed_event(kind: 1, content: "other", seckey: Fixtures.seckey2())
      wire = JSON.encode!(["EVENT", event_to_map(event_from_other)])

      {:push, {:text, msg}, _state} = Socket.handle_in({wire, opcode: :text}, state)
      {:ok, {:auth, _new_challenge}} = Message.parse(msg)
    end
  end

  defp init_state, do: Socket.init([]) |> elem(1)

  defp event_to_map(%Event{} = event) do
    %{
      "id" => event.id,
      "pubkey" => event.pubkey,
      "kind" => event.kind,
      "tags" =>
        Enum.map(event.tags, fn
          %{type: type, data: nil} -> [type]
          %{type: type, data: data, info: info} -> [type, data | info]
        end),
      "created_at" => DateTime.to_unix(event.created_at),
      "content" => event.content,
      "sig" => event.sig
    }
  end
end
