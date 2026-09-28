if Code.ensure_loaded?(Ecto.Query) do
  defmodule Noxir.Store.SQLite do
    @moduledoc """
    SQLite-backed store via Ecto (exqlite).

    Requires `:ecto_sql` and `:ecto_sqlite3` as optional deps. The host app
    provides a supervised `Ecto.Repo` with the `Ecto.Adapters.SQLite3` adapter;
    the repo module is configured via `config :noxir, :store_opts, repo: MyApp.Repo`.

    Tables are created at boot (idempotent `CREATE TABLE IF NOT EXISTS`) —
    the database lives in a single file, so point it at a persistent volume.

        CREATE TABLE nostr_events (
          id TEXT PRIMARY KEY,
          pubkey TEXT NOT NULL,
          kind INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          content TEXT NOT NULL,
          sig TEXT NOT NULL,
          tags TEXT NOT NULL
        )

    Tag filters are served through a normalized `nostr_tags` table with an
    `(tag_type, tag_value)` index.
    """

    @behaviour Noxir.Store

    import Ecto.Query

    alias NostrCore.{Event, Filter, Kinds, Tag}

    @table "nostr_events"
    @tags_table "nostr_tags"

    defmodule Owner do
      @moduledoc false
      use GenServer

      alias Noxir.Store.SQLite

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(_opts) do
        Enum.each(SQLite.ddl(), &SQLite.repo().query!(&1))
        {:ok, %{}}
      end
    end

    @impl true
    def child_spec(opts) do
      %{
        id: __MODULE__.Owner,
        start: {__MODULE__.Owner, :start_link, [opts]},
        type: :worker
      }
    end

    @impl true
    def insert(%Event{} = event) do
      repo().transaction(fn ->
        maybe_delete_old(event)
        insert_event(event)
      end)
      |> case do
        {:ok, _} -> {:ok, event}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def query(filters) when is_list(filters) do
      filters
      |> Enum.flat_map(&query_single/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&DateTime.to_unix(&1.created_at), :desc)
    end

    @impl true
    def get(event_id) when is_binary(event_id) do
      from(e in @table,
        select: {e.id, e.pubkey, e.kind, e.created_at, e.content, e.sig, e.tags},
        where: e.id == ^event_id
      )
      |> repo().one()
      |> row_to_event()
    end

    @impl true
    def delete(event_id) when is_binary(event_id) do
      repo().transaction(fn ->
        repo().delete_all(from(e in @table, where: e.id == ^event_id))
        repo().delete_all(from(t in @tags_table, where: t.event_id == ^event_id))
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def count(filters) when is_list(filters) do
      filters
      |> Enum.map(&build_query/1)
      |> Enum.reduce(nil, fn q, acc ->
        if acc, do: Ecto.Query.union_all(acc, ^q), else: q
      end)
      |> then(&repo().aggregate(&1, :count))
    end

    defp insert_event(%Event{} = event) do
      repo().insert_all(@table, [event_to_row(event)],
        on_conflict: :nothing,
        conflict_target: :id
      )

      repo().insert_all(@tags_table, tag_rows(event))
      {:ok, event}
    end

    # ── Query building ──────────────────────────────────────

    defp query_single(%Filter{} = filter) do
      filter
      |> build_query()
      |> repo().all()
      |> Enum.map(&row_to_event/1)
      |> apply_limit(filter.limit)
    end

    defp build_query(%Filter{} = filter) do
      from(e in @table,
        select: {e.id, e.pubkey, e.kind, e.created_at, e.content, e.sig, e.tags},
        where: ^build_wheres(filter),
        order_by: [desc: e.created_at]
      )
    end

    defp build_wheres(filter) do
      true
      |> add_id_where(filter.ids)
      |> add_pubkey_where(filter.authors)
      |> add_kind_where(filter.kinds)
      |> add_since_where(filter.since)
      |> add_until_where(filter.until)
      |> add_tag_wheres(filter.tags)
    end

    defp add_id_where(q, nil), do: q
    defp add_id_where(q, []), do: q
    defp add_id_where(q, ids), do: dynamic([e], e.id in ^ids and ^q)

    defp add_pubkey_where(q, nil), do: q
    defp add_pubkey_where(q, []), do: q
    defp add_pubkey_where(q, authors), do: dynamic([e], e.pubkey in ^authors and ^q)

    defp add_kind_where(q, nil), do: q
    defp add_kind_where(q, []), do: q
    defp add_kind_where(q, kinds), do: dynamic([e], e.kind in ^kinds and ^q)

    defp add_since_where(q, nil), do: q

    defp add_since_where(q, since), do: dynamic([e], e.created_at >= ^DateTime.to_unix(since) and ^q)

    defp add_until_where(q, nil), do: q
    defp add_until_where(q, until), do: dynamic([e], e.created_at <= ^DateTime.to_unix(until) and ^q)

    defp add_tag_wheres(q, nil), do: q
    defp add_tag_wheres(q, tags) when map_size(tags) == 0, do: q

    defp add_tag_wheres(q, tags) do
      Enum.reduce(tags, q, fn {"#" <> letter, values}, acc ->
        tag_matches =
          from(t in @tags_table,
            where: t.tag_type == ^letter and t.tag_value in ^values,
            select: t.event_id
          )

        dynamic([e], e.id in subquery(tag_matches) and ^acc)
      end)
    end

    defp apply_limit(results, nil), do: results
    defp apply_limit(results, n) when is_integer(n) and n > 0, do: Enum.take(results, n)
    defp apply_limit(results, _), do: results

    # ── Replaceable ─────────────────────────────────────────

    defp maybe_delete_old(%Event{} = event) do
      cond do
        Kinds.replaceable?(event) ->
          delete_old_by_pubkey_kind(event.pubkey, event.kind, event.id)

        Kinds.parameterized_replaceable?(event) ->
          delete_old_parameterized(event.pubkey, event.kind, d_tag_values(event.tags), event.id)

        true ->
          :ok
      end
    end

    defp delete_old_by_pubkey_kind(pubkey, kind, new_id) do
      ids_query =
        from(e in @table,
          where: e.pubkey == ^pubkey and e.kind == ^kind and e.id != ^new_id,
          select: e.id
        )

      repo().delete_all(from(e in @table, where: e.id in subquery(ids_query)))
      repo().delete_all(from(t in @tags_table, where: t.event_id in subquery(ids_query)))
      :ok
    end

    defp delete_old_parameterized(pubkey, kind, d_tags, new_id) do
      if d_tags != [] do
        ids_query =
          from(e in @table,
            where: e.pubkey == ^pubkey and e.kind == ^kind and e.id != ^new_id,
            where: e.id in subquery(tag_matches(d_tags)),
            select: e.id
          )

        repo().delete_all(from(e in @table, where: e.id in subquery(ids_query)))
        repo().delete_all(from(t in @tags_table, where: t.event_id in subquery(ids_query)))
      end

      :ok
    end

    defp tag_matches(d_tags) do
      from(t in @tags_table,
        where: t.tag_type == "d" and t.tag_value in ^d_tags,
        select: t.event_id
      )
    end

    # ── Serialization ───────────────────────────────────────

    defp event_to_row(%Event{} = event) do
      %{
        id: event.id,
        pubkey: event.pubkey,
        kind: event.kind,
        created_at: DateTime.to_unix(event.created_at),
        content: event.content,
        sig: event.sig,
        tags: JSON.encode!(serialize_tags(event.tags))
      }
    end

    defp tag_rows(%Event{} = event) do
      Enum.map(event.tags, fn
        %Tag{data: nil} = tag -> %{event_id: event.id, tag_type: tag.type, tag_value: ""}
        %Tag{} = tag -> %{event_id: event.id, tag_type: tag.type, tag_value: tag.data}
      end)
    end

    defp serialize_tags(tags) do
      Enum.map(tags, fn
        %Tag{data: nil} = tag -> [tag.type]
        %Tag{} = tag -> [tag.type, tag.data | tag.info]
      end)
    end

    defp row_to_event(nil), do: nil

    defp row_to_event({id, pubkey, kind, created_at, content, sig, tags}) do
      %Event{
        id: id,
        pubkey: pubkey,
        kind: kind,
        created_at: DateTime.from_unix!(created_at),
        content: content,
        sig: sig,
        tags: deserialize_tags(tags)
      }
    end

    defp deserialize_tags(nil), do: []

    defp deserialize_tags(tags) do
      case JSON.decode!(tags) do
        list when is_list(list) ->
          Enum.map(list, fn
            [type] -> %Tag{type: type}
            [type, data | info] -> %Tag{type: type, data: data, info: info}
          end)
      end
    end

    defp d_tag_values(tags) do
      Enum.flat_map(tags, fn
        %Tag{type: "d", data: value} when is_binary(value) -> [value]
        _ -> []
      end)
    end

    # ── Schema ──────────────────────────────────────────────

    @doc false
    def repo, do: Keyword.fetch!(Application.fetch_env!(:noxir, :store_opts), :repo)

    def ddl do
      [
        """
        CREATE TABLE IF NOT EXISTS nostr_events (
          id TEXT PRIMARY KEY,
          pubkey TEXT NOT NULL,
          kind INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          content TEXT NOT NULL,
          sig TEXT NOT NULL,
          tags TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS nostr_events_pubkey_idx ON nostr_events(pubkey)",
        "CREATE INDEX IF NOT EXISTS nostr_events_kind_idx ON nostr_events(kind)",
        """
        CREATE TABLE IF NOT EXISTS nostr_tags (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          event_id TEXT NOT NULL,
          tag_type TEXT NOT NULL,
          tag_value TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS nostr_tags_tag_idx ON nostr_tags(tag_type, tag_value)",
        "CREATE INDEX IF NOT EXISTS nostr_tags_event_id_idx ON nostr_tags(event_id)"
      ]
    end
  end
end
