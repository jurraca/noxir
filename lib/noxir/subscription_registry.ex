defmodule Noxir.SubscriptionRegistry do
  @moduledoc """
  Subscription routing via `:pg` process groups keyed by configurable index keys.

  Each connection joins pg groups for the values extracted from its subscription
  filters based on the configured index keys (e.g. `:authors`, `:kinds`, `:"#h"`).
  On event insert, the registry queries pg groups for the event's index values,
  unions the candidate pids, and each candidate runs `Noxir.Filter.match?/2`
  locally for final confirmation.

  Subscriptions with no values for any configured index key are rejected by
  `Noxir.Policy` before reaching the registry — no wildcard group, no flooding.

  ETS-backed refcounting handles overlapping subscriptions from the same
  connection. `:pg` automatically removes dead processes from groups.

  The public API is a pure module operating on public ETS tables — no GenServer
  serialization on the hot path. A small `Owner` process creates the tables and
  pg scope at boot.

  ## Configuration

      # general relay (default)
      config :noxir, :subscription_index_keys, [:authors]

      # community relay — index by author and channel
      config :noxir, :subscription_index_keys, [:authors, :"#h"]

  Supported key types:
    * `:authors` — maps to `Filter.authors` / `Event.pubkey`
    * `:kinds` — maps to `Filter.kinds` / `Event.kind`
    * `:"#x"` — maps to `Filter.tags["#x"]` / `Event.tags` where `Tag.type == "x"`
  """

  alias NostrCore.{Event, Filter, Tag}

  @pg_scope :noxir_subscriptions
  @subs_table :noxir_subscription_index
  @refcount_table :noxir_index_refcounts
  @max_mailbox_len 1000

  def pg_scope, do: @pg_scope
  def subs_table, do: @subs_table
  def refcount_table, do: @refcount_table

  defmodule Owner do
    @moduledoc false
    use GenServer

    alias Noxir.SubscriptionRegistry

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      :pg.start_link(SubscriptionRegistry.pg_scope())

      :ets.new(SubscriptionRegistry.subs_table(), [:set, :public, :named_table, read_concurrency: true])
      :ets.new(SubscriptionRegistry.refcount_table(), [:set, :public, :named_table, read_concurrency: true])
      {:ok, %{}}
    end
  end

  @doc "Register a subscription. Replaces any existing subscription with the same sub_id."
  @spec register(pid(), binary(), [Filter.t()]) :: :ok
  def register(pid, sub_id, filters) when is_list(filters) do
    unregister(pid, sub_id)

    index_values = extract_index_values(filters)

    :ets.insert(@subs_table, {{pid, sub_id}, index_values})

    Enum.each(index_values, fn {key, value} ->
      ref_key = {pid, key, value}
      new_count = :ets.update_counter(@refcount_table, ref_key, {2, 1}, {ref_key, 0})

      if new_count == 1 do
        :pg.join(@pg_scope, {key, value}, pid)
      end
    end)

    :ok
  end

  @doc "Unregister a subscription by sub_id."
  @spec unregister(pid(), binary()) :: :ok
  def unregister(pid, sub_id) do
    case :ets.lookup(@subs_table, {pid, sub_id}) do
      [{{^pid, ^sub_id}, index_values}] ->
        :ets.delete(@subs_table, {pid, sub_id})
        Enum.each(index_values, &decrement_ref(pid, &1))

      [] ->
        :ok
    end

    :ok
  end

  @doc "Unregister all subscriptions for a pid (called on connection terminate)."
  @spec unregister_all(pid()) :: :ok
  def unregister_all(pid) do
    @subs_table
    |> :ets.match({{pid, :"$1"}, :"$2"})
    |> Enum.each(fn [sub_id, _index_values] ->
      unregister(pid, sub_id)
    end)

    :ok
  end

  @doc "Get candidate pids that might be interested in an event."
  @spec get_candidates(Event.t()) :: [pid()]
  def get_candidates(%Event{} = event) do
    event
    |> extract_event_index_values()
    |> Enum.flat_map(fn {key, value} ->
      :pg.get_members(@pg_scope, {key, value})
    end)
    |> Enum.uniq()
  end

  def get_candidates(_), do: []

  @doc """
  Dispatch an event to all matching subscribers except the sender.

  Checks each candidate's mailbox depth and skips slow subscribers to prevent
  memory pressure from backpressured clients.
  """
  @spec dispatch(Event.t(), pid() | nil) :: :ok
  def dispatch(%Event{} = event, from_pid) do
    event
    |> get_candidates()
    |> Enum.reject(&(&1 == from_pid))
    |> Enum.each(fn pid ->
      unless mailbox_overflow?(pid) do
        send(pid, {:event, event})
      end
    end)

    :ok
  end

  defp decrement_ref(pid, {key, value}) do
    ref_key = {pid, key, value}

    case :ets.update_counter(@refcount_table, ref_key, {2, -1}, {ref_key, 1}) do
      0 ->
        :ets.delete(@refcount_table, ref_key)
        :pg.leave(@pg_scope, {key, value}, pid)

      _ ->
        :ok
    end
  end

  defp mailbox_overflow?(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len > @max_mailbox_len
      nil -> true
    end
  end

  defp index_keys, do: Application.get_env(:noxir, :subscription_index_keys, [:authors])

  # ── Extract index values from filters (on register) ────

  defp extract_index_values(filters) do
    filters
    |> Enum.flat_map(&filter_index_values/1)
    |> Enum.uniq()
  end

  defp filter_index_values(%Filter{} = filter) do
    Enum.flat_map(index_keys(), fn key ->
      filter_values_for_key(filter, key)
    end)
  end

  defp filter_values_for_key(%Filter{authors: authors}, :authors) when is_list(authors) do
    Enum.map(authors, &{:authors, &1})
  end

  defp filter_values_for_key(%Filter{kinds: kinds}, :kinds) when is_list(kinds) do
    Enum.map(kinds, &{:kinds, &1})
  end

  defp filter_values_for_key(%Filter{tags: tags}, key) do
    str_key = Atom.to_string(key)

    if String.starts_with?(str_key, "#") do
      case Map.get(tags || %{}, str_key) do
        nil -> []
        values -> Enum.map(values, &{key, &1})
      end
    else
      []
    end
  end

  defp filter_values_for_key(_, _), do: []

  # ── Extract index values from event (on dispatch) ──────

  defp extract_event_index_values(%Event{} = event) do
    Enum.flat_map(index_keys(), fn key ->
      event_values_for_key(event, key)
    end)
  end

  defp event_values_for_key(%Event{pubkey: pubkey}, :authors) when is_binary(pubkey) do
    [{:authors, pubkey}]
  end

  defp event_values_for_key(%Event{kind: kind}, :kinds) when is_integer(kind) do
    [{:kinds, kind}]
  end

  defp event_values_for_key(%Event{tags: tags}, key) do
    str_key = Atom.to_string(key)

    if String.starts_with?(str_key, "#") do
      letter = String.slice(str_key, 1..-1//1)

      Enum.flat_map(tags, fn
        %Tag{type: type, data: value} when type == letter and is_binary(value) -> [{key, value}]
        _ -> []
      end)
    else
      []
    end
  end

  defp event_values_for_key(_, _), do: []
end
