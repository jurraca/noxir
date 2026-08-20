defmodule Noxir.Store.ETS do
  @moduledoc """
  In-memory ETS store. Zero external dependencies. Default for dev/test and
  small single-node relays.

  Tables (public, owned by `Noxir.Store.ETS.Owner`):

    * `:noxir_ets_events` — `:set`, key `event_id`, value `{unix, %Event{}}`
    * `:noxir_ets_by_author` — `:bag`, key `pubkey`, value `event_id`
    * `:noxir_ets_tag_index` — `:bag`, key `{tag_type, tag_value}`, value `event_id`

  Replaceable/parameterized delete-old is not atomic across concurrent inserts
  of the same pubkey+kind — acceptable for dev/test. Use `Noxir.Store.Mnesia`
  or `Noxir.Store.Postgres` for production.
  """

  @behaviour Noxir.Store

  alias NostrCore.{Event, Filter, Kinds, Tag}

  @events_table :noxir_ets_events
  @author_table :noxir_ets_by_author
  @tag_table :noxir_ets_tag_index

  defmodule Owner do
    @moduledoc false
    use GenServer

    @events_table :noxir_ets_events
    @author_table :noxir_ets_by_author
    @tag_table :noxir_ets_tag_index

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      :ets.new(@events_table, [:set, :public, :named_table, read_concurrency: true])
      :ets.new(@author_table, [:bag, :public, :named_table, read_concurrency: true])
      :ets.new(@tag_table, [:bag, :public, :named_table, read_concurrency: true])
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
    unix = DateTime.to_unix(event.created_at)

    maybe_delete_old(event)

    :ets.insert(@events_table, {event.id, unix, event})
    :ets.insert(@author_table, {event.pubkey, event.id})

    for %Tag{type: type, data: value} when is_binary(value) <- event.tags do
      :ets.insert(@tag_table, {{type, value}, event.id})
    end

    {:ok, event}
  end

  @impl true
  def query(filters) when is_list(filters) do
    filters
    |> Enum.flat_map(&query_single/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&DateTime.to_unix(&1.created_at), :desc)
  end

  defp query_single(%Filter{} = filter) do
    results = select_strategy(filter)
    apply_limit(results, filter.limit)
  end

  defp select_strategy(%Filter{ids: ids} = filter) when is_list(ids) and ids != [] do
    ids
    |> Enum.flat_map(&lookup_event(&1, filter))
    |> Enum.sort_by(&DateTime.to_unix(&1.created_at), :desc)
  end

  defp select_strategy(%Filter{authors: authors} = filter) when is_list(authors) and authors != [] do
    authors
    |> Enum.flat_map(&:ets.lookup(@author_table, &1))
    |> Enum.flat_map(&lookup_event_by_ref(&1, filter))
    |> Enum.sort_by(&DateTime.to_unix(&1.created_at), :desc)
  end

  defp select_strategy(%Filter{tags: tags} = filter) when is_map(tags) and map_size(tags) > 0 do
    tags
    |> Enum.flat_map(&lookup_tag/1)
    |> Enum.flat_map(&lookup_event_by_ref(&1, filter))
    |> Enum.sort_by(&DateTime.to_unix(&1.created_at), :desc)
  end

  defp select_strategy(%Filter{} = filter), do: scan_all(filter)

  defp apply_limit(results, nil), do: results
  defp apply_limit(results, n) when is_integer(n) and n > 0, do: Enum.take(results, n)
  defp apply_limit(results, _), do: results

  defp lookup_event(id, filter) do
    case :ets.lookup(@events_table, id) do
      [{^id, _unix, event}] -> if Noxir.Filter.match?(filter, event), do: [event], else: []
      [] -> []
    end
  end

  defp lookup_event_by_ref({_key, event_id}, filter) do
    case :ets.lookup(@events_table, event_id) do
      [{^event_id, _unix, event}] -> if Noxir.Filter.match?(filter, event), do: [event], else: []
      [] -> []
    end
  end

  defp lookup_tag({"#" <> tag_letter, values}) do
    Enum.flat_map(values, fn value ->
      :ets.lookup(@tag_table, {tag_letter, value})
    end)
  end

  defp scan_all(%Filter{} = filter) do
    @events_table
    |> :ets.tab2list()
    |> Enum.flat_map(fn {_id, _unix, event} ->
      if Noxir.Filter.match?(filter, event), do: [event], else: []
    end)
    |> Enum.sort_by(&DateTime.to_unix(&1.created_at), :desc)
  end

  @impl true
  def get(event_id) when is_binary(event_id) do
    case :ets.lookup(@events_table, event_id) do
      [{^event_id, _unix, event}] -> event
      [] -> nil
    end
  end

  @impl true
  def delete(event_id) when is_binary(event_id) do
    case :ets.lookup(@events_table, event_id) do
      [{^event_id, _unix, %Event{pubkey: pubkey, tags: tags}}] ->
        :ets.delete(@events_table, event_id)
        :ets.delete_object(@author_table, {pubkey, event_id})

        for %Tag{type: type, data: value} when is_binary(value) <- tags do
          :ets.delete_object(@tag_table, {{type, value}, event_id})
        end

        :ok

      [] ->
        :ok
    end
  end

  @impl true
  def count(filters) when is_list(filters) do
    length(query(filters))
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
    @author_table
    |> :ets.lookup(pubkey)
    |> Enum.each(fn {^pubkey, event_id} ->
      case :ets.lookup(@events_table, event_id) do
        [{^event_id, _unix, %Event{kind: ^kind}}] when event_id != new_id ->
          delete(event_id)

        _ ->
          :ok
      end
    end)
  end

  defp delete_old_parameterized(pubkey, kind, d_tags, new_id) do
    @author_table
    |> :ets.lookup(pubkey)
    |> Enum.each(&maybe_delete_parameterized(&1, kind, d_tags, new_id))
  end

  defp maybe_delete_parameterized({_pubkey, event_id}, kind, d_tags, new_id) do
    case :ets.lookup(@events_table, event_id) do
      [{^event_id, _unix, %Event{kind: ^kind, tags: event_tags}}]
      when event_id != new_id ->
        if d_tags_overlap?(d_tags, event_tags), do: delete(event_id)

      _ ->
        :ok
    end
  end

  defp d_tags_overlap?(d_tags, event_tags) do
    event_d_tags = d_tag_values(event_tags)
    Enum.any?(d_tags, &(&1 in event_d_tags))
  end

  defp d_tag_values(tags) when is_list(tags) do
    Enum.flat_map(tags, fn
      %Tag{type: "d", data: value} when is_binary(value) -> [value]
      _ -> []
    end)
  end
end
