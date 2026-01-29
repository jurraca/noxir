defmodule Noxir.Store do
  @moduledoc """
  Manages Mnesia table initialization and cluster node monitoring.
  
  Event storage is handled directly by Relay processes via `Noxir.Relay.Events`,
  avoiding serialization bottlenecks.
  """

  use GenServer

  alias __MODULE__.Connection
  alias __MODULE__.Event
  alias Event.TagIndex
  alias Memento.Table

  @tables [
    Connection,
    Event,
    TagIndex
  ]

  @spec start_link([GenServer.option()]) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: NoxirStore)
  end

  @impl GenServer
  def init(options) do
    :ok = :net_kernel.monitor_nodes(true)

    for table <- @tables do
      Table.create!(table)
    end

    :ok = Table.wait(@tables, :infinity)

    {:ok, options}
  end

  @impl GenServer
  def handle_info({:nodeup, _}, state) do
    {:noreply, state}
  end

  def handle_info({:nodedown, _}, state) do
    {:ok, _} = Memento.add_nodes(Node.list())
    {:noreply, state}
  end

  @spec change_to_existing_atom_key(map()) :: map()
  def change_to_existing_atom_key(map) do
    for {key, val} <- map, into: %{} do
      key =
        try do
          String.to_existing_atom(key)
        rescue
          _ -> key
        end

      {key, val}
    end
  end

  @spec to_map(struct()) :: map()
  def to_map(%{__meta__: Table} = map) do
    map
    |> Map.from_struct()
    |> Map.delete(:__meta__)
  end
end
