defmodule Noxir.SubscriptionIndex do
  @moduledoc """
  Manages subscription routing using pg process groups.
  
  Connections join pg groups keyed by author pubkeys from their filters.
  When an event arrives, we query the author's group to find candidate
  pids that might be interested.
  
  Uses ETS to track subscription -> authors mapping and refcounts per author
  to properly handle overlapping subscriptions from the same connection.
  """

  use GenServer

  @pg_scope :noxir_subscriptions
  @subs_table :noxir_subscription_authors
  @refcount_table :noxir_author_refcounts

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :pg.start_link(@pg_scope)
    :ets.new(@subs_table, [:set, :public, :named_table])
    :ets.new(@refcount_table, [:set, :public, :named_table])
    {:ok, %{}}
  end

  @doc """
  Register a subscription for the given pid.
  
  Extracts author pubkeys from filters and joins pg groups for each.
  Tracks the subscription's authors for later unregistration.
  
  If a subscription with the same sub_id already exists, it is replaced
  (the old authors are unregistered first).
  """
  @spec register(pid(), binary(), [map()]) :: :ok
  def register(pid, sub_id, filters) when is_list(filters) do
    unregister(pid, sub_id)
    
    authors = extract_authors(filters)
    
    :ets.insert(@subs_table, {{pid, sub_id}, authors})
    
    Enum.each(authors, fn author ->
      key = {pid, author}
      new_count = :ets.update_counter(@refcount_table, key, {2, 1}, {key, 0})
      
      if new_count == 1 do
        :pg.join(@pg_scope, {:author, author}, pid)
      end
    end)

    :ok
  end

  @doc """
  Unregister a subscription.
  
  Leaves pg groups for authors that no longer have any subscriptions
  from this pid interested in them.
  """
  @spec unregister(pid(), binary()) :: :ok
  def unregister(pid, sub_id) do
    case :ets.lookup(@subs_table, {pid, sub_id}) do
      [{{^pid, ^sub_id}, authors}] ->
        :ets.delete(@subs_table, {pid, sub_id})
        
        Enum.each(authors, fn author ->
          key = {pid, author}
          case :ets.update_counter(@refcount_table, key, {2, -1}, {key, 1}) do
            0 ->
              :ets.delete(@refcount_table, key)
              :pg.leave(@pg_scope, {:author, author}, pid)
            _ ->
              :ok
          end
        end)
        
      [] ->
        :ok
    end
    
    :ok
  end

  @doc """
  Unregister all subscriptions for a pid.
  
  Called when a connection terminates. Cleans up all ETS entries
  and leaves all pg groups.
  """
  @spec unregister_all(pid()) :: :ok
  def unregister_all(pid) do
    @subs_table
    |> :ets.match({{pid, :"$1"}, :"$2"})
    |> Enum.each(fn [sub_id, _authors] ->
      unregister(pid, sub_id)
    end)
    
    :ok
  end

  @doc """
  Get candidate pids that might be interested in an event.
  
  Queries the pg group for the event's author pubkey.
  Returns a list of pids that have subscribed to that author.
  """
  @spec get_candidates(map() | struct()) :: [pid()]
  def get_candidates(%{pubkey: author}) when is_binary(author) do
    :pg.get_members(@pg_scope, {:author, author})
  end

  def get_candidates(_), do: []

  defp extract_authors(filters) do
    filters
    |> Enum.flat_map(fn
      %{"authors" => authors} when is_list(authors) -> authors
      %{authors: authors} when is_list(authors) -> authors
      _ -> []
    end)
    |> Enum.uniq()
  end
end
