defmodule Noxir.Policy.DefaultTest do
  use ExUnit.Case, async: false

  alias NostrCore.Filter
  alias Noxir.Policy.Default
  alias Noxir.Test.Fixtures

  setup do
    Default.init(required: false, allowed_pubkeys: [], index_keys_required: [:authors])
    :ok
  end

  describe "auth_required?/0" do
    test "defaults to false" do
      assert Default.auth_required?() == false
    end

    test "can be set to true" do
      Default.set_auth_required(true)
      assert Default.auth_required?() == true
      Default.set_auth_required(false)
    end
  end

  describe "allowed_pubkey?/1" do
    test "empty allowlist allows all" do
      assert Default.allowed_pubkey?("anykey") == true
    end

    test "non-empty allowlist restricts to listed keys" do
      Default.set_pubkeys(["abc", "def"])
      assert Default.allowed_pubkey?("abc") == true
      assert Default.allowed_pubkey?("xyz") == false
      Default.clear_pubkeys()
    end

    test "add and remove pubkeys" do
      Default.set_pubkeys(["key1", "key2"])
      assert Default.allowed_pubkey?("key1") == true
      assert Default.allowed_pubkey?("key2") == true

      Default.remove_pubkey("key1")
      assert Default.allowed_pubkey?("key1") == false
      assert Default.allowed_pubkey?("key2") == true

      Default.clear_pubkeys()
    end
  end

  describe "index_keys_required?/0" do
    test "returns configured keys" do
      assert Default.index_keys_required?() == [:authors]
    end
  end

  describe "classify_event/1" do
    test "kind 22_242 is ephemeral" do
      event = Fixtures.signed_event(kind: 22_242)
      assert Default.classify_event(event) == :ephemeral
    end

    test "kind 20_000 is ephemeral" do
      event = Fixtures.signed_event(kind: 20_000)
      assert Default.classify_event(event) == :ephemeral
    end

    test "kind 1 is stored" do
      event = Fixtures.signed_event(kind: 1)
      assert Default.classify_event(event) == :store
    end
  end

  describe "allow_req?/2 with :authors required" do
    test "rejects REQ without authors" do
      filters = [%Filter{kinds: [1]}]
      assert {:error, message} = Default.allow_req?(filters, nil)
      assert String.contains?(message, "author")
    end

    test "allows REQ with authors" do
      filters = [%Filter{authors: [Fixtures.pubkey()], kinds: [1]}]
      assert :ok = Default.allow_req?(filters, nil)
    end

    test "rejects if any filter lacks authors" do
      filters = [
        %Filter{authors: [Fixtures.pubkey()], kinds: [1]},
        %Filter{kinds: [2]}
      ]

      assert {:error, _} = Default.allow_req?(filters, nil)
    end
  end

  describe "allow_req?/2 with :authors + :#h required" do
    setup do
      Default.init(required: false, allowed_pubkeys: [], index_keys_required: [:authors, :"#h"])
      :ok
    end

    test "allows REQ with authors only" do
      filters = [%Filter{authors: [Fixtures.pubkey()]}]
      assert :ok = Default.allow_req?(filters, nil)
    end

    test "allows REQ with #h tag only" do
      filters = [%Filter{tags: %{"#h" => ["community1"]}}]
      assert :ok = Default.allow_req?(filters, nil)
    end

    test "rejects REQ with neither authors nor #h" do
      filters = [%Filter{kinds: [1]}]
      assert {:error, _} = Default.allow_req?(filters, nil)
    end
  end

  describe "allow_req?/2 with no keys required" do
    setup do
      Default.init(required: false, allowed_pubkeys: [], index_keys_required: [])
      :ok
    end

    test "allows any REQ" do
      filters = [%Filter{kinds: [1]}]
      assert :ok = Default.allow_req?(filters, nil)
    end
  end
end
