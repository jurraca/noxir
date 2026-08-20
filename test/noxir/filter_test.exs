defmodule Noxir.FilterTest do
  use ExUnit.Case, async: true

  alias NostrCore.Filter
  alias Noxir.Test.Fixtures

  describe "match?/2 with single filter" do
    test "empty filter list matches everything" do
      event = Fixtures.signed_event()
      assert Noxir.Filter.match?([], event) == true
    end

    test "match by ids" do
      event = Fixtures.signed_event()
      filter = %Filter{ids: [event.id]}
      assert Noxir.Filter.match?(filter, event) == true

      filter2 = %Filter{ids: ["nonexistent"]}
      assert Noxir.Filter.match?(filter2, event) == false
    end

    test "match by authors" do
      event = Fixtures.signed_event()
      filter = %Filter{authors: [event.pubkey]}
      assert Noxir.Filter.match?(filter, event) == true

      filter2 = %Filter{authors: [Fixtures.pubkey2()]}
      assert Noxir.Filter.match?(filter2, event) == false
    end

    test "match by kinds" do
      event = Fixtures.signed_event(kind: 1)
      filter = %Filter{kinds: [1]}
      assert Noxir.Filter.match?(filter, event) == true

      filter2 = %Filter{kinds: [2]}
      assert Noxir.Filter.match?(filter2, event) == false
    end

    test "match by since/until" do
      event = Fixtures.signed_event(created_at: ~U[2024-06-01 00:00:00Z])

      assert Noxir.Filter.match?(%Filter{since: ~U[2024-01-01 00:00:00Z]}, event) == true
      assert Noxir.Filter.match?(%Filter{since: ~U[2025-01-01 00:00:00Z]}, event) == false
      assert Noxir.Filter.match?(%Filter{until: ~U[2025-01-01 00:00:00Z]}, event) == true
      assert Noxir.Filter.match?(%Filter{until: ~U[2024-01-01 00:00:00Z]}, event) == false
    end

    test "match by tags" do
      tag = NostrCore.Tag.create!("t", "nostr")
      event = Fixtures.signed_event(tags: [tag])
      filter = %Filter{tags: %{"#t" => ["nostr"]}}

      assert Noxir.Filter.match?(filter, event) == true

      filter2 = %Filter{tags: %{"#t" => ["bitcoin"]}}
      assert Noxir.Filter.match?(filter2, event) == false
    end

    test "nil and empty lists match as wildcards" do
      event = Fixtures.signed_event()

      assert Noxir.Filter.match?(%Filter{ids: nil}, event) == true
      assert Noxir.Filter.match?(%Filter{ids: []}, event) == true
      assert Noxir.Filter.match?(%Filter{authors: nil}, event) == true
      assert Noxir.Filter.match?(%Filter{authors: []}, event) == true
      assert Noxir.Filter.match?(%Filter{kinds: nil}, event) == true
      assert Noxir.Filter.match?(%Filter{kinds: []}, event) == true
      assert Noxir.Filter.match?(%Filter{tags: nil}, event) == true
      assert Noxir.Filter.match?(%Filter{tags: %{}}, event) == true
    end

    test "combined filters (AND)" do
      event = Fixtures.signed_event(kind: 1)
      filter = %Filter{authors: [event.pubkey], kinds: [1]}
      assert Noxir.Filter.match?(filter, event) == true

      filter2 = %Filter{authors: [event.pubkey], kinds: [2]}
      assert Noxir.Filter.match?(filter2, event) == false
    end
  end

  describe "match?/2 with filter list (OR)" do
    test "any filter matching returns true" do
      event = Fixtures.signed_event(kind: 1)

      filters = [
        %Filter{kinds: [2]},
        %Filter{kinds: [1]},
        %Filter{kinds: [3]}
      ]

      assert Noxir.Filter.match?(filters, event) == true
    end

    test "no filters matching returns false" do
      event = Fixtures.signed_event(kind: 1)

      filters = [
        %Filter{kinds: [2]},
        %Filter{kinds: [3]}
      ]

      assert Noxir.Filter.match?(filters, event) == false
    end
  end
end
