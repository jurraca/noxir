defmodule Noxir.Store.Mnesia do
  @moduledoc """
  Mnesia-backed store via Memento.

  Supports `ram_copies` (default — data lost on restart) and `disc_copies`
  (opt-in via `config :noxir, :mnesia_dir`).

  Tables:

    * `Noxir.Store.Mnesia.Event` — events with indexed `pubkey`, `kind`,
      `created_at`
    * `Noxir.Store.Mnesia.TagIndex` — `{tag_type, value, event_id}` with
      indexed `tag_kind`, `value`, `event_id`

  Replaceable/parameterized delete-old runs inside the insert transaction.
  Table creation uses `Memento.Table.create/2` (not `create!/1`) so restarts
  don't crash when tables already exist.
  """

  @behaviour Noxir.Store

  alias NostrCore.{Event, Filter, Kinds, Tag}

  defmodule EventTable do
    @moduledoc false
    use Memento.Table,
      attributes: [:id, :pubkey, :created_at, :kind, :tags, :content, :sig],
      index: [:pubkey, :kind, :created_at]
  end

  defmodule TagIndex do
    @moduledoc false
    use Memento.Table,
      attributes: [:id, :tag_kind, :value, :event_id],
      index: [:tag_kind, :value, :event_id],
      type: :ordered_set,
      autoincrement: true
  end

  defmodule Owner do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      disc? = Keyword.get(opts, :disc, false)
      dir = Keyword.get(opts, :mnesia_dir)

      if disc? and dir do
        File.mkdir_p!(dir)
        Application.put_env(:mnesia, :dir, dir)
        Memento.Schema.create([node()])
      end

      tables = [EventTable, TagIndex]

      for table <- tables do
        case Memento.Table.create(table) do
          :ok -> :ok
          {:already_exists, ^table} -> :ok
          {:error, _} = err -> raise "failed to create #{inspect(table)}: #{inspect(err)}"
        end
      end

      :ok = Memento.Table.wait(tables, :infinity)
      {:ok, %{}}
    end
  end

  @impl true
  def child_spec(opts) do
    {mnesia_opts, rest} = Keyword.split(opts, [:disc, :mnesia_dir])
    merged = Keyword.merge(Application.get_all_env(:noxir), mnesia_opts)

    %{
      id: __MODULE__.Owner,
      start: {__MODULE__.Owner, :start_link, [merged ++ rest]},
      type: :worker
    }
  end

  @impl true
  def insert(%Event{} = event) do
    Memento.transaction(fn ->
      maybe_delete_old(event)
      do_insert(event)
    end)
    |> case do
      {:ok, event} -> {:ok, event}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @impl true
  def query(filters) when is_list(filters) do
    Memento.transaction(fn ->
      filters
      |> Enum.flat_map(&query_single/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&DateTime.to_unix(&1.created_at), :desc)
    end)
    |> case do
      {:ok, results} -> results
      {:aborted, _} -> []
    end
  end

  @impl true
  def get(event_id) when is_binary(event_id) do
    Memento.transaction(fn ->
      case Memento.Query.read(EventTable, event_id) do
        nil -> nil
        record -> to_event(record)
      end
    end)
    |> case do
      {:ok, event} -> event
      {:aborted, _} -> nil
    end
  end

  @impl true
  def delete(event_id) when is_binary(event_id) do
    Memento.transaction(fn ->
      case Memento.Query.read(EventTable, event_id) do
        nil ->
          :ok

        record ->
          remove_tag_index(event_id, record.tags)
          Memento.Query.delete_record(record)
          :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @impl true
  def count(filters) when is_list(filters) do
    length(query(filters))
  end

  # ── Insert helpers ──────────────────────────────────────

  defp do_insert(%Event{} = event) do
    record = %EventTable{
      id: event.id,
      pubkey: event.pubkey,
      created_at: DateTime.to_unix(event.created_at),
      kind: event.kind,
      tags: serialize_tags(event.tags),
      content: event.content,
      sig: event.sig
    }

    Memento.Query.write(record)
    add_tag_index(event.id, event.tags)
    event
  end

  defp maybe_delete_old(%Event{} = event) do
    cond do
      Kinds.replaceable?(event) ->
        delete_old_by_pubkey_kind(event.pubkey, event.kind, event.id)

      Kinds.parameterized_replaceable?(event) ->
        d_tags = d_tag_values(event.tags)
        delete_old_parameterized(event.pubkey, event.kind, d_tags, event.id)

      true ->
        :ok
    end
  end

  defp delete_old_by_pubkey_kind(pubkey, kind, new_id) do
    EventTable
    |> Memento.Query.select([{:==, :pubkey, pubkey}, {:==, :kind, kind}])
    |> Enum.reject(&(&1.id == new_id))
    |> Enum.each(&delete_record/1)
  end

  defp delete_old_parameterized(pubkey, kind, d_tags, new_id) do
    EventTable
    |> Memento.Query.select([{:==, :pubkey, pubkey}, {:==, :kind, kind}])
    |> Enum.reject(&(&1.id == new_id))
    |> Enum.filter(fn record ->
      event_d_tags = d_tag_values_from_serialized(record.tags)
      Enum.any?(d_tags, &(&1 in event_d_tags))
    end)
    |> Enum.each(&delete_record/1)
  end

  defp delete_record(%EventTable{id: id, tags: tags} = record) do
    remove_tag_index(id, deserialize_tags(tags))
    Memento.Query.delete_record(record)
  end

  # ── Tag index ───────────────────────────────────────────

  defp add_tag_index(event_id, tags) do
    for %Tag{type: type, data: value} when is_binary(value) <- tags do
      existing =
        TagIndex
        |> Memento.Query.select([
          {:==, :tag_kind, type},
          {:==, :value, value},
          {:==, :event_id, event_id}
        ])

      if existing == [] do
        Memento.Query.write(%TagIndex{tag_kind: type, value: value, event_id: event_id})
      end
    end
  end

  defp remove_tag_index(event_id, tags) do
    for %Tag{type: type, data: value} when is_binary(value) <- tags do
      TagIndex
      |> Memento.Query.select([
        {:==, :tag_kind, type},
        {:==, :value, value},
        {:==, :event_id, event_id}
      ])
      |> Enum.each(&Memento.Query.delete_record/1)
    end
  end

  # ── Query helpers ───────────────────────────────────────

  defp query_single(%Filter{} = filter) do
    case tag_ids_from_filter(filter) do
      {:ok, ids} ->
        select_events(filter, ids)
        |> Enum.sort_by(& &1.created_at, :desc)
        |> apply_limit(filter.limit)

      :skip ->
        base_query(filter)
        |> Enum.sort_by(& &1.created_at, :desc)
        |> apply_limit(filter.limit)

      :not_found ->
        []
    end
  end

  defp tag_ids_from_filter(%Filter{tags: nil}), do: :skip
  defp tag_ids_from_filter(%Filter{tags: tags}) when map_size(tags) == 0, do: :skip

  defp tag_ids_from_filter(%Filter{tags: tags}) do
    Enum.reduce_while(tags, {:ok, nil}, fn {"#" <> letter, values}, {:ok, acc} ->
      ids = get_tag_ids(letter, values)

      cond do
        ids == [] -> {:halt, :not_found}
        acc == nil -> {:cont, {:ok, ids}}
        true -> {:cont, {:ok, Enum.filter(acc, &(&1 in ids))}}
      end
    end)
  end

  defp get_tag_ids(letter, values) do
    TagIndex
    |> Memento.Query.select([
      {:==, :tag_kind, letter},
      List.to_tuple([:or | Enum.map(values, &{:==, :value, &1})])
    ])
    |> Enum.map(& &1.event_id)
  end

  defp select_events(filter, nil) do
    base_query(filter)
  end

  defp select_events(filter, ids) do
    filter
    |> base_query()
    |> Enum.filter(&(&1.id in ids))
  end

  defp base_query(%Filter{} = filter) do
    query =
      []
      |> add_id_clause(filter.ids)
      |> add_pubkey_clause(filter.authors)
      |> add_kind_clause(filter.kinds)
      |> add_since_clause(filter.since)
      |> add_until_clause(filter.until)

    EventTable
    |> Memento.Query.select(query)
    |> Enum.map(&to_event/1)
    |> Enum.filter(&Noxir.Filter.match?(filter, &1))
  end

  defp add_id_clause(q, nil), do: q
  defp add_id_clause(q, []), do: q
  defp add_id_clause(q, [id]), do: [{:==, :id, id} | q]
  defp add_id_clause(q, ids), do: [List.to_tuple([:or | Enum.map(ids, &{:==, :id, &1})]) | q]

  defp add_pubkey_clause(q, nil), do: q
  defp add_pubkey_clause(q, []), do: q
  defp add_pubkey_clause(q, [p]), do: [{:==, :pubkey, p} | q]

  defp add_pubkey_clause(q, authors),
    do: [List.to_tuple([:or | Enum.map(authors, &{:==, :pubkey, &1})]) | q]

  defp add_kind_clause(q, nil), do: q
  defp add_kind_clause(q, []), do: q
  defp add_kind_clause(q, [k]), do: [{:==, :kind, k} | q]

  defp add_kind_clause(q, kinds),
    do: [List.to_tuple([:or | Enum.map(kinds, &{:==, :kind, &1})]) | q]

  defp add_since_clause(q, nil), do: q
  defp add_since_clause(q, since), do: [{:>=, :created_at, DateTime.to_unix(since)} | q]

  defp add_until_clause(q, nil), do: q
  defp add_until_clause(q, until), do: [{:<=, :created_at, DateTime.to_unix(until)} | q]

  defp apply_limit(results, nil), do: results
  defp apply_limit(results, n) when is_integer(n) and n > 0, do: Enum.take(results, n)
  defp apply_limit(results, _), do: results

  # ── Serialization ───────────────────────────────────────

  defp serialize_tags(tags) do
    Enum.map(tags, fn
      %Tag{data: nil} = tag -> [tag.type]
      %Tag{} = tag -> [tag.type, tag.data | tag.info]
    end)
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

  defp d_tag_values_from_serialized(tags) do
    Enum.flat_map(tags, fn
      ["d", value | _] -> [value]
      _ -> []
    end)
  end

  defp to_event(%EventTable{} = record) do
    %Event{
      id: record.id,
      pubkey: record.pubkey,
      created_at: DateTime.from_unix!(record.created_at),
      kind: record.kind,
      tags: deserialize_tags(record.tags),
      content: record.content,
      sig: record.sig
    }
  end
end
