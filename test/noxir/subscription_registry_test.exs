defmodule Noxir.SubscriptionRegistryTest do
  use ExUnit.Case, async: false

  alias NostrCore.{Filter, Tag}
  alias Noxir.SubscriptionRegistry
  alias Noxir.Test.Fixtures

  setup do
    Application.ensure_all_started(:noxir)
    Application.put_env(:noxir, :subscription_index_keys, [:authors])
    SubscriptionRegistry.unregister_all(self())
    :ok
  end

  describe "register/3 with :authors index (default)" do
    test "joins pg groups for filter authors" do
      pid = self()
      filters = [%Filter{authors: [Fixtures.pubkey()]}]

      assert :ok = SubscriptionRegistry.register(pid, "sub1", filters)

      event = Fixtures.signed_event()
      candidates = SubscriptionRegistry.get_candidates(event)
      assert pid in candidates
    end

    test "replaces existing subscription with same sub_id" do
      pid = self()

      SubscriptionRegistry.register(pid, "sub1", [%Filter{authors: [Fixtures.pubkey()]}])
      SubscriptionRegistry.register(pid, "sub1", [%Filter{authors: [Fixtures.pubkey2()]}])

      event1 = Fixtures.signed_event(seckey: Fixtures.seckey())
      event2 = Fixtures.signed_event(seckey: Fixtures.seckey2())

      assert pid not in SubscriptionRegistry.get_candidates(event1)
      assert pid in SubscriptionRegistry.get_candidates(event2)
    end
  end

  describe "unregister/2" do
    test "leaves pg groups when last subscription to a key is removed" do
      pid = self()
      SubscriptionRegistry.register(pid, "sub1", [%Filter{authors: [Fixtures.pubkey()]}])

      assert :ok = SubscriptionRegistry.unregister(pid, "sub1")

      event = Fixtures.signed_event()
      assert pid not in SubscriptionRegistry.get_candidates(event)
    end

    test "refcount keeps pg group when overlapping subscriptions exist" do
      pid = self()

      SubscriptionRegistry.register(pid, "sub1", [%Filter{authors: [Fixtures.pubkey()]}])
      SubscriptionRegistry.register(pid, "sub2", [%Filter{authors: [Fixtures.pubkey()]}])

      SubscriptionRegistry.unregister(pid, "sub1")

      event = Fixtures.signed_event()
      assert pid in SubscriptionRegistry.get_candidates(event)

      SubscriptionRegistry.unregister(pid, "sub2")

      assert pid not in SubscriptionRegistry.get_candidates(event)
    end
  end

  describe "unregister_all/1" do
    test "removes all subscriptions for a pid" do
      pid = self()

      SubscriptionRegistry.register(pid, "sub1", [%Filter{authors: [Fixtures.pubkey()]}])
      SubscriptionRegistry.register(pid, "sub2", [%Filter{authors: [Fixtures.pubkey2()]}])

      assert :ok = SubscriptionRegistry.unregister_all(pid)

      event1 = Fixtures.signed_event(seckey: Fixtures.seckey())
      event2 = Fixtures.signed_event(seckey: Fixtures.seckey2())

      assert pid not in SubscriptionRegistry.get_candidates(event1)
      assert pid not in SubscriptionRegistry.get_candidates(event2)
    end
  end

  describe "dispatch/2" do
    test "sends event to matching subscribers" do
      pid = self()
      SubscriptionRegistry.register(pid, "sub1", [%Filter{authors: [Fixtures.pubkey()]}])

      event = Fixtures.signed_event()
      assert :ok = SubscriptionRegistry.dispatch(event, nil)

      assert_received {:event, ^event}
    end

    test "excludes the sender" do
      pid = self()
      SubscriptionRegistry.register(pid, "sub1", [%Filter{authors: [Fixtures.pubkey()]}])

      event = Fixtures.signed_event()
      SubscriptionRegistry.dispatch(event, pid)

      refute_received {:event, _}
    end
  end

  describe "multi-key index (:authors + :#h)" do
    setup do
      Application.put_env(:noxir, :subscription_index_keys, [:authors, :"#h"])
      :ok
    end

    test "indexes by both authors and #h tag" do
      pid = self()

      h_tag = Tag.create!("h", "community1")

      filters = [%Filter{authors: [Fixtures.pubkey()], tags: %{"#h" => ["community1"]}}]
      assert :ok = SubscriptionRegistry.register(pid, "sub1", filters)

      event = Fixtures.signed_event(tags: [h_tag])
      assert pid in SubscriptionRegistry.get_candidates(event)
    end

    test "subscription with only #h tag matches event with that tag" do
      pid = self()

      h_tag = Tag.create!("h", "community1")

      filters = [%Filter{tags: %{"#h" => ["community1"]}}]
      assert :ok = SubscriptionRegistry.register(pid, "sub1", filters)

      event = Fixtures.signed_event(tags: [h_tag])
      assert pid in SubscriptionRegistry.get_candidates(event)
    end

    test "subscription by author only still matches via author group" do
      pid = self()

      filters = [%Filter{authors: [Fixtures.pubkey()]}]
      assert :ok = SubscriptionRegistry.register(pid, "sub1", filters)

      event = Fixtures.signed_event()
      assert pid in SubscriptionRegistry.get_candidates(event)
    end

    test "union: event matching either key reaches subscriber" do
      pid = self()

      # Subscribe to a different author but same #h channel
      filters = [%Filter{authors: [Fixtures.pubkey2()], tags: %{"#h" => ["community1"]}}]
      assert :ok = SubscriptionRegistry.register(pid, "sub1", filters)

      # Event from pubkey (not pubkey2) but with #h community1 tag
      h_tag = Tag.create!("h", "community1")
      event = Fixtures.signed_event(tags: [h_tag])
      assert pid in SubscriptionRegistry.get_candidates(event)
    end
  end

  describe "kinds index" do
    setup do
      Application.put_env(:noxir, :subscription_index_keys, [:kinds])
      :ok
    end

    test "indexes by kind" do
      pid = self()

      filters = [%Filter{kinds: [1]}]
      assert :ok = SubscriptionRegistry.register(pid, "sub1", filters)

      event = Fixtures.signed_event(kind: 1)
      assert pid in SubscriptionRegistry.get_candidates(event)

      event2 = Fixtures.signed_event(kind: 2)
      assert pid not in SubscriptionRegistry.get_candidates(event2)
    end
  end
end
