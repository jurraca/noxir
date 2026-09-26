defmodule Noxir.Store.SQLiteTest do
  use ExUnit.Case, async: false

  alias NostrCore.{Filter, Tag}
  alias Noxir.Store.SQLite
  alias Noxir.Test.Fixtures

  setup do
    Application.put_env(:noxir, :sqlite_repo, Noxir.Test.SQLiteRepo)

    db =
      Path.join(
        System.tmp_dir!(),
        "noxir_test_#{System.monotonic_time()}_#{:rand.uniform(1_000_000)}.db"
      )

    Application.put_env(:noxir, Noxir.Test.SQLiteRepo, database: db)

    on_exit(fn ->
      File.rm_rf(db)
      File.rm_rf(db <> "-wal")
      File.rm_rf(db <> "-shm")
    end)

    start_supervised!(Noxir.Test.SQLiteRepo)
    start_supervised!(Noxir.Store.SQLite.Owner)
    :ok
  end

  describe "insert/1" do
    test "stores a regular event" do
      event = Fixtures.signed_event(kind: 1, content: "hello")

      assert {:ok, ^event} = SQLite.insert(event)

      result = SQLite.query([%Filter{authors: [event.pubkey]}])
      assert length(result) == 1
      assert hd(result).id == event.id
    end

    test "stores an event with tags and queries by tag" do
      tag = Tag.create!("e", "abc123")
      event = Fixtures.signed_event(kind: 1, tags: [tag])

      {:ok, _} = SQLite.insert(event)

      result = SQLite.query([%Filter{tags: %{"#e" => ["abc123"]}}])
      assert length(result) == 1
      assert hd(result).id == event.id
    end

    test "replaceable kind 0 overwrites older version" do
      old = Fixtures.signed_event(kind: 0, content: "old profile", created_at: ~U[2024-01-01 00:00:00Z])
      new = Fixtures.signed_event(kind: 0, content: "new profile", created_at: ~U[2024-06-01 00:00:00Z])

      {:ok, _} = SQLite.insert(old)
      {:ok, _} = SQLite.insert(new)

      result = SQLite.query([%Filter{authors: [Fixtures.pubkey()], kinds: [0]}])
      assert length(result) == 1
      assert hd(result).content == "new profile"
    end

    test "parameterized replaceable kind 30000 overwrites by d-tag" do
      d_tag = Tag.create!("d", "article-1")

      old =
        Fixtures.signed_event(
          kind: 30_023,
          content: "v1",
          tags: [d_tag],
          created_at: ~U[2024-01-01 00:00:00Z]
        )

      new =
        Fixtures.signed_event(
          kind: 30_023,
          content: "v2",
          tags: [d_tag],
          created_at: ~U[2024-06-01 00:00:00Z]
        )

      {:ok, _} = SQLite.insert(old)
      {:ok, _} = SQLite.insert(new)

      result = SQLite.query([%Filter{authors: [Fixtures.pubkey()], kinds: [30_023]}])
      assert length(result) == 1
      assert hd(result).content == "v2"
    end

    test "parameterized replaceable preserves different d-tags" do
      tag_a = Tag.create!("d", "article-a")
      tag_b = Tag.create!("d", "article-b")

      event_a = Fixtures.signed_event(kind: 30_023, content: "a", tags: [tag_a])
      event_b = Fixtures.signed_event(kind: 30_023, content: "b", tags: [tag_b])

      {:ok, _} = SQLite.insert(event_a)
      {:ok, _} = SQLite.insert(event_b)

      result = SQLite.query([%Filter{authors: [Fixtures.pubkey()], kinds: [30_023]}])
      assert length(result) == 2
    end
  end

  describe "query/1" do
    test "returns events newest first" do
      e1 = Fixtures.signed_event(kind: 1, content: "old", created_at: ~U[2024-01-01 00:00:00Z])
      e2 = Fixtures.signed_event(kind: 1, content: "new", created_at: ~U[2024-06-01 00:00:00Z])

      {:ok, _} = SQLite.insert(e1)
      {:ok, _} = SQLite.insert(e2)

      result = SQLite.query([%Filter{authors: [Fixtures.pubkey()]}])
      assert hd(result).id == e2.id
      assert List.last(result).id == e1.id
    end

    test "deduplicates across filters" do
      event = Fixtures.signed_event(kind: 1)
      {:ok, _} = SQLite.insert(event)

      result =
        SQLite.query([
          %Filter{authors: [event.pubkey]},
          %Filter{kinds: [1]}
        ])

      assert length(result) == 1
    end

    test "applies limit per filter" do
      for i <- 1..5 do
        ts = DateTime.add(~U[2024-01-01 00:00:00Z], i * 86_400)

        {:ok, _} =
          Fixtures.signed_event(kind: 1, content: "e#{i}", created_at: ts)
          |> SQLite.insert()
      end

      result = SQLite.query([%Filter{authors: [Fixtures.pubkey()], limit: 3}])
      assert length(result) == 3
    end

    test "query by ids" do
      event = Fixtures.signed_event(kind: 1)
      {:ok, _} = SQLite.insert(event)

      result = SQLite.query([%Filter{ids: [event.id]}])
      assert length(result) == 1
    end

    test "query by since/until" do
      old = Fixtures.signed_event(kind: 1, created_at: ~U[2024-01-01 00:00:00Z])
      new = Fixtures.signed_event(kind: 1, created_at: ~U[2024-06-01 00:00:00Z])

      {:ok, _} = SQLite.insert(old)
      {:ok, _} = SQLite.insert(new)

      result = SQLite.query([%Filter{authors: [Fixtures.pubkey()], since: ~U[2024-03-01 00:00:00Z]}])
      assert length(result) == 1
      assert hd(result).id == new.id
    end

    test "requires all tag letters to match" do
      e_tag = Tag.create!("e", "ref123")
      p_tag = Tag.create!("p", "pubkey456")
      event = Fixtures.signed_event(kind: 1, tags: [e_tag, p_tag])
      {:ok, _} = SQLite.insert(event)

      result = SQLite.query([%Filter{tags: %{"#e" => ["ref123"], "#p" => ["pubkey456"]}}])
      assert length(result) == 1

      result = SQLite.query([%Filter{tags: %{"#e" => ["ref123"], "#p" => ["nope"]}}])
      assert result == []
    end
  end

  describe "delete/1" do
    test "deletes an event by id" do
      event = Fixtures.signed_event(kind: 1)
      {:ok, _} = SQLite.insert(event)

      assert :ok = SQLite.delete(event.id)

      result = SQLite.query([%Filter{ids: [event.id]}])
      assert result == []
    end

    test "cleans up tag index on delete" do
      tag = Tag.create!("e", "ref123")
      event = Fixtures.signed_event(kind: 1, tags: [tag])
      {:ok, _} = SQLite.insert(event)

      :ok = SQLite.delete(event.id)

      result = SQLite.query([%Filter{tags: %{"#e" => ["ref123"]}}])
      assert result == []
    end
  end

  describe "count/1" do
    test "counts matching events" do
      e1 = Fixtures.signed_event(kind: 1, content: "a")
      e2 = Fixtures.signed_event(kind: 1, content: "b")

      {:ok, _} = SQLite.insert(e1)
      {:ok, _} = SQLite.insert(e2)

      assert SQLite.count([%Filter{authors: [Fixtures.pubkey()]}]) == 2
    end
  end
end
