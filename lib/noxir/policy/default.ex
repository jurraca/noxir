defmodule Noxir.Policy.Default do
  @moduledoc """
  Default policy impl backed by `:persistent_term`.

  Auth allowlist can be updated at runtime via `add_pubkey/1`, `remove_pubkey/1`,
  `set_pubkeys/1`, `clear_pubkeys/0`. Reads are lock-free (important since
  `allowed_pubkey?/1` is called on every EVENT and REQ).
  """

  @behaviour Noxir.Policy

  alias NostrCore.{Event, Filter, Kinds}

  @auth_required_key {__MODULE__, :auth_required}
  @allowed_pubkeys_key {__MODULE__, :allowed_pubkeys}
  @index_keys_required_key {__MODULE__, :index_keys_required}

  @impl true
  def init(opts) do
    :persistent_term.put(@auth_required_key, Keyword.get(opts, :required, false))

    :persistent_term.put(
      @allowed_pubkeys_key,
      MapSet.new(Keyword.get(opts, :allowed_pubkeys, []))
    )

    :persistent_term.put(
      @index_keys_required_key,
      Keyword.get(opts, :index_keys_required, [:authors])
    )

    :ok
  end

  @impl true
  def auth_required? do
    :persistent_term.get(@auth_required_key, false)
  end

  @impl true
  def allowed_pubkey?(pubkey) do
    pubkeys = :persistent_term.get(@allowed_pubkeys_key, MapSet.new())
    MapSet.size(pubkeys) == 0 or MapSet.member?(pubkeys, pubkey)
  end

  @impl true
  def index_keys_required? do
    :persistent_term.get(@index_keys_required_key, [:authors])
  end

  @impl true
  def classify_event(%Event{kind: 22_242}), do: :ephemeral

  def classify_event(%Event{} = event) do
    if Kinds.ephemeral?(event), do: :ephemeral, else: :store
  end

  @impl true
  def allow_req?(filters, _pubkey) do
    required = index_keys_required?()

    if required != [] and not filters_have_index_keys?(filters, required) do
      {:error, "rejected: at least an author, tag or kind is required"}
    else
      :ok
    end
  end

  defp filters_have_index_keys?([], _required), do: false

  defp filters_have_index_keys?(filters, required) do
    Enum.all?(filters, fn %Filter{} = filter ->
      Enum.any?(required, &filter_has_key?(filter, &1))
    end)
  end

  defp filter_has_key?(%Filter{authors: a}, :authors), do: is_list(a) and a != []
  defp filter_has_key?(%Filter{kinds: k}, :kinds), do: is_list(k) and k != []

  defp filter_has_key?(%Filter{tags: tags}, key) do
    str_key = Atom.to_string(key)

    if String.starts_with?(str_key, "#") do
      case Map.get(tags || %{}, str_key) do
        nil -> false
        [] -> false
        _ -> true
      end
    else
      false
    end
  end

  # Runtime management

  def set_auth_required(required) when is_boolean(required) do
    :persistent_term.put(@auth_required_key, required)
    :ok
  end

  def get_allowed_pubkeys do
    :persistent_term.get(@allowed_pubkeys_key, MapSet.new()) |> MapSet.to_list()
  end

  def set_pubkeys(pubkeys) when is_list(pubkeys) do
    :persistent_term.put(@allowed_pubkeys_key, MapSet.new(pubkeys))
    :ok
  end

  def add_pubkey(pubkey) when is_binary(pubkey) do
    pubkeys = :persistent_term.get(@allowed_pubkeys_key, MapSet.new())
    :persistent_term.put(@allowed_pubkeys_key, MapSet.put(pubkeys, pubkey))
    :ok
  end

  def remove_pubkey(pubkey) when is_binary(pubkey) do
    pubkeys = :persistent_term.get(@allowed_pubkeys_key, MapSet.new())
    :persistent_term.put(@allowed_pubkeys_key, MapSet.delete(pubkeys, pubkey))
    :ok
  end

  def clear_pubkeys do
    :persistent_term.put(@allowed_pubkeys_key, MapSet.new())
    :ok
  end
end
