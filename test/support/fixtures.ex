defmodule Noxir.Test.Fixtures do
  @moduledoc "Test helpers for creating signed Nostr events."

  @seckey "1111111111111111111111111111111111111111111111111111111111111111"
  @pubkey "4f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa"
  @seckey2 "2222222222222222222222222222222222222222222222222222222222222222"
  @pubkey2 "466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27"

  def seckey, do: @seckey
  def pubkey, do: @pubkey
  def seckey2, do: @seckey2
  def pubkey2, do: @pubkey2

  def signed_event(opts \\ []) do
    kind = Keyword.get(opts, :kind, 1)
    content = Keyword.get(opts, :content, "test")
    tags = Keyword.get(opts, :tags, [])
    sk = Keyword.get(opts, :seckey, @seckey)
    ts = Keyword.get(opts, :created_at, ~U[2024-01-01 00:00:00Z])

    kind
    |> NostrCore.Event.create!(content: content, tags: tags, created_at: ts)
    |> NostrCore.Event.sign!(sk)
  end

  def raw_event_map(opts \\ []) do
    event = signed_event(opts)

    %{
      "id" => event.id,
      "pubkey" => event.pubkey,
      "kind" => event.kind,
      "tags" =>
        Enum.map(event.tags, fn
          %{type: type, data: nil} -> [type]
          %{type: type, data: data, info: info} -> [type, data | info]
        end),
      "created_at" => DateTime.to_unix(event.created_at),
      "content" => event.content,
      "sig" => event.sig
    }
  end

  def wire_event(opts \\ []) do
    JSON.encode!(["EVENT", raw_event_map(opts)])
  end

  def wire_req(sub_id, filters) do
    JSON.encode!(["REQ", sub_id | filters])
  end

  def wire_close(sub_id) do
    JSON.encode!(["CLOSE", sub_id])
  end

  def parse_response({:push, {opcode, msg}, _state}) when is_binary(msg) do
    {:ok, parsed} = NostrCore.Message.parse(msg)
    {opcode, parsed}
  end

  def parse_response({:push, msgs, _state}) when is_list(msgs) do
    Enum.map(msgs, fn {opcode, msg} ->
      {:ok, parsed} = NostrCore.Message.parse(msg)
      {opcode, parsed}
    end)
  end
end
