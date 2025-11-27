defmodule Noxir.Broadcaster do
  @moduledoc """
  Handles event broadcasting to subscribed connections.
  
  Receives events from Store and fans out to candidate pids
  based on SubscriptionIndex lookups. This keeps the Store
  GenServer out of the broadcast hot path.
  """

  use GenServer

  alias Noxir.SubscriptionIndex
  alias Noxir.Store.Event

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
  end

  @doc """
  Broadcast an event to interested subscribers.
  
  Called by Store after persisting an event. Queries SubscriptionIndex
  for candidate pids and sends the event to each.
  """
  @spec broadcast(Event.t(), pid()) :: :ok
  def broadcast(%Event{} = event, from_pid) do
    GenServer.cast(__MODULE__, {:broadcast, event, from_pid})
  end

  @impl GenServer
  def handle_cast({:broadcast, %Event{} = event, from_pid}, state) do
    event
    |> SubscriptionIndex.get_candidates()
    |> Enum.reject(&(&1 == from_pid))
    |> Enum.each(fn pid ->
      Process.send(pid, {:create_event, event}, [])
    end)

    {:noreply, state}
  end
end
