defmodule Noxir.Relay.Events do
  @moduledoc """
  Handles event storage and broadcasting for Nostr relay connections.
  
  Functions in this module run in the calling Relay process, not a separate GenServer.
  This avoids serialization bottlenecks on event writes.
  """

  alias Noxir.Store.Event
  alias Noxir.SubscriptionIndex

  require Logger

  @spec store(map()) :: {:ok, binary()} | {:error, binary()}
  def store(event) do
    case Memento.transaction(fn -> Event.create(event) end) do
      {:ok, ev} ->
        broadcast(ev)
        {:ok, ""}

      {:error, reason} ->
        Logger.debug(reason)
        {:error, "Something went wrong"}
    end
  end

  @spec replace(map(), :replaceable | :parameterized) :: {:ok, binary()} | {:error, binary()}
  def replace(event, type) do
    case Memento.transaction(fn -> Event.create(event) end) do
      {:ok, ev} ->
        broadcast(ev)
        delete_old(ev, type)
        {:ok, ""}

      {:error, reason} ->
        Logger.debug(reason)
        {:error, "Something went wrong"}
    end
  end

  defp broadcast(%Event{} = event) do
    from = self()

    Task.start(fn ->
      event
      |> SubscriptionIndex.get_candidates()
      |> Enum.reject(&(&1 == from))
      |> Enum.each(fn pid ->
        Process.send(pid, {:event_published, event}, [])
      end)
    end)
  end

  defp delete_old(%Event{pubkey: pkey, kind: kind}, :replaceable) do
    Memento.transaction!(fn ->
      Event.delete_old(pkey, kind)
    end)
  end

  defp delete_old(%Event{pubkey: pkey, kind: kind, tags: tags}, :parameterized) do
    dtags =
      tags
      |> Enum.filter(fn
        ["d", _ | _] -> true
        _ -> false
      end)
      |> Enum.map(fn [_, tag | _] -> tag end)

    Memento.transaction!(fn ->
      Event.delete_old(pkey, kind, dtags)
    end)
  end
end
