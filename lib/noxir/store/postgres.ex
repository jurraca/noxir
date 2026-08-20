defmodule Noxir.Store.Postgres do
  @moduledoc """
  PostgreSQL-backed store via Ecto.

  Requires `:ecto_sql` and `:postgrex` as optional deps. The host app provides
  a supervised `Ecto.Repo`; this store delegates to it. The repo module is
  configured via `config :noxir, :postgres_repo, MyApp.Repo`.

  Schema:

      create table(:nostr_events, primary_key: false) do
        add :id, :string, primary_key: true, size: 64
        add :pubkey, :string, size: 64, null: false
        add :kind, :integer, null: false
        add :created_at, :integer, null: false
        add :content, :text, null: false
        add :sig, :string, size: 128, null: false
        add :tags, :jsonb, null: false
      end

      create index(:nostr_events, [:pubkey])
      create index(:nostr_events, [:kind])
      create index(:nostr_events, [:created_at])
      create index(:nostr_events, [:pubkey, :kind])
      # GIN index for tag filtering
      create index(:nostr_events, ["tags"], using: :gin)

  Replaceable/parameterized delete-old runs in a single SQL transaction.
  NIP-09 deletion is a single `DELETE` by id.
  """

  @behaviour Noxir.Store

  import Ecto.Query

  alias NostrCore.{Event, Filter, Kinds, Tag}

  @table "nostr_events"

  @impl true
  def child_spec(opts) do
    ensure_loaded!()
    # The host app owns the Repo supervision; no process needed here.
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc false
  def start_link(_opts), do: :ignore

  @impl true
  def insert(%Event{} = event) do
    ensure_loaded!()

    repo().transaction(fn ->
      maybe_delete_old(event)
      repo().insert_all(@table, [event_to_row(event)],
        on_conflict: :nothing,
        conflict_target: :id
      )
    end)
    |> case do
      {:ok, _} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def query(filters) when is_list(filters) do
    ensure_loaded!()

    filters
    |> Enum.flat_map(&query_single/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&DateTime.to_unix(&1.created_at), :desc)
  end

  @impl true
  def get(event_id) when is_binary(event_id) do
    ensure_loaded!()

    from(e in @table,
      where: e.id == ^event_id,
      select: {e.id, e.pubkey, e.kind, e.created_at, e.content, e.sig, e.tags}
    )
    |> repo().one()
    |> case do
      nil -> nil
      row -> row_to_event(row)
    end
  end

  @impl true
  def delete(event_id) when is_binary(event_id) do
    ensure_loaded!()

    repo().transaction(fn ->
      repo().delete_all(from(e in @table, where: e.id == ^event_id))
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def count(filters) when is_list(filters) do
    ensure_loaded!()

    filters
    |> Enum.map(&build_query/1)
    |> Enum.reduce(nil, fn q, acc ->
      if acc, do: Ecto.Query.union_all(acc, ^q), else: q
    end)
    |> then(&repo().aggregate(&1, :count))
  end

  # ── Query building ──────────────────────────────────────

  defp query_single(%Filter{} = filter) do
    filter
    |> build_query()
    |> repo().all()
    |> Enum.map(&row_to_event/1)
    |> apply_limit(filter.limit)
  end

  defp build_query(%Filter{} = filter)
       when filter.ids == nil and filter.authors == nil and filter.kinds == nil and
              filter.since == nil and filter.until == nil and
              (filter.tags == nil or map_size(filter.tags) == 0) do
    from(e in @table,
      select: {e.id, e.pubkey, e.kind, e.created_at, e.content, e.sig, e.tags},
      order_by: [desc: e.created_at]
    )
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
      # tags column is [["e","abc"],["p","pubkey"],...] (jsonb array of arrays).
      # @> checks containment: tags @> '[["e","abc"]]' means "tags contains the
      # tag ["e","abc"]". We OR across values for same-letter semantics.
      conditions =
        Enum.map(values, fn value ->
          tag_json = JSON.encode!([[letter, value]])
          dynamic([e], fragment("tags @> ?::jsonb", ^tag_json))
        end)

      tag_dyn = Enum.reduce(conditions, fn cond1, cond2 -> dynamic([e], ^cond1 or ^cond2) end)
      dynamic([e], ^tag_dyn and ^acc)
    end)
  end

  defp apply_limit(results, nil), do: results
  defp apply_limit(results, n) when is_integer(n) and n > 0, do: Enum.take(results, n)
  defp apply_limit(results, _), do: results

  # ── Replaceable ─────────────────────────────────────────

  defp maybe_delete_old(%Event{} = event) do
    cond do
      Kinds.replaceable?(event) ->
        delete_replaceable(event)

      Kinds.parameterized_replaceable?(event) ->
        delete_parameterized(event)

      true ->
        :ok
    end
  end

  defp delete_replaceable(%Event{} = event) do
    repo().delete_all(
      from(e in @table,
        where: e.pubkey == ^event.pubkey and e.kind == ^event.kind and e.id != ^event.id
      )
    )
  end

  defp delete_parameterized(%Event{} = event) do
    d_tags = d_tag_values(event.tags)

    if d_tags != [] do
      # Match any d-tag value: tags @> '[["d","val1"]]' OR tags @> '[["d","val2"]]'
      conditions =
        Enum.map(d_tags, fn value ->
          tag_json = JSON.encode!([["d", value]])
          dynamic([e], fragment("tags @> ?::jsonb", ^tag_json))
        end)

      tag_dyn = Enum.reduce(conditions, fn c1, c2 -> dynamic([e], ^c1 or ^c2) end)

      repo().delete_all(
        from(e in @table,
          where:
            e.pubkey == ^event.pubkey and e.kind == ^event.kind and
              e.id != ^event.id and
              ^tag_dyn
        )
      )
    end
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
      tags: serialize_tags(event.tags),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp serialize_tags(tags) do
    Enum.map(tags, fn
      %Tag{data: nil} = tag -> [tag.type]
      %Tag{} = tag -> [tag.type, tag.data | tag.info]
    end)
  end

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

  defp deserialize_tags(tags) do
    Enum.map(tags, fn
      [type] -> %Tag{type: type}
      [type, data | info] -> %Tag{type: type, data: data, info: info}
    end)
  end

  defp d_tag_values(tags) do
    Enum.flat_map(tags, fn
      %Tag{type: "d", data: value} when is_binary(value) -> [value]
      _ -> []
    end)
  end

  # ── Helpers ─────────────────────────────────────────────

  defp repo, do: Application.fetch_env!(:noxir, :postgres_repo)

  defp ensure_loaded! do
    unless Code.ensure_loaded?(Ecto) do
      raise "Noxir.Store.Postgres requires :ecto_sql and :postgrex. Add them to your deps."
    end
  end
end
