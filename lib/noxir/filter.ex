defmodule Noxir.Filter do
  @moduledoc """
  In-memory filter/event matching.

  `NostrCore.Filter` owns parsing and encoding; this module owns the matching
  logic used by `Noxir.SubscriptionRegistry` for fan-out and by Store impls
  for in-memory query refinement.
  """

  import Kernel, except: [match?: 2]

  alias NostrCore.{Event, Filter, Tag}

  @spec match?([Filter.t()] | Filter.t(), Event.t()) :: boolean()
  def match?([], _), do: true
  def match?(filters, event) when is_list(filters), do: Enum.any?(filters, &match?(&1, event))

  def match?(%Filter{} = filter, %Event{} = event) do
    match_ids?(filter.ids, event.id) and
      match_authors?(filter.authors, event.pubkey) and
      match_kinds?(filter.kinds, event.kind) and
      match_range?(filter.since, filter.until, event.created_at) and
      match_tags?(filter.tags, event.tags)
  end

  defp match_ids?(nil, _), do: true
  defp match_ids?([], _), do: true
  defp match_ids?(ids, id), do: id in ids

  defp match_authors?(nil, _), do: true
  defp match_authors?([], _), do: true
  defp match_authors?(authors, pubkey), do: pubkey in authors

  defp match_kinds?(nil, _), do: true
  defp match_kinds?([], _), do: true
  defp match_kinds?(kinds, kind), do: kind in kinds

  defp match_range?(nil, nil, _), do: true

  defp match_range?(since, until, created_at) do
    unix = DateTime.to_unix(created_at)

    (since == nil or DateTime.to_unix(since) <= unix) and
      (until == nil or unix <= DateTime.to_unix(until))
  end

  defp match_tags?(nil, _), do: true
  defp match_tags?(tags, _event_tags) when map_size(tags) == 0, do: true

  defp match_tags?(tags, event_tags) do
    Enum.all?(tags, fn {"#" <> tag_letter, values} ->
      Enum.any?(event_tags, fn
        %Tag{type: type, data: data} when is_binary(data) ->
          type == tag_letter and data in values

        _ ->
          false
      end)
    end)
  end
end
