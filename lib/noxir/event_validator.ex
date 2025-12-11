defmodule Noxir.EventValidator do
  @moduledoc """
  Validates Nostr events according to the protocol specification.
  """

  @doc """
  Validates a Nostr event by checking its ID and signature.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, String.t()}
  def validate(event) do
    with :ok <- validate_required_fields(event),
         :ok <- validate_id(event),
         :ok <- validate_signature(event) do
      {:ok, event}
    end
  end

  defp validate_required_fields(%{"id" => _, "pubkey" => _, "created_at" => _, "kind" => _, "tags" => _, "content" => _, "sig" => _}) do
    :ok
  end

  defp validate_required_fields(_), do: {:error, "missing required fields"}

  defp validate_id(%{"id" => id} = event) do
    case compute_event_id(event) do
      ^id -> :ok
      _ -> {:error, "invalid: event id does not match"}
    end
  end

  defp validate_signature(%{"id" => id, "sig" => sig, "pubkey" => pubkey}) do
    try do
      case Secp256k1.schnorr_valid?(
        Base.decode16!(sig, case: :lower),
        Base.decode16!(id, case: :lower),
        Base.decode16!(pubkey, case: :lower)
      ) do
        true -> :ok
        false -> {:error, "invalid: signature verification failed"}
      end
    rescue
      _ -> {:error, "invalid: malformed signature or pubkey"}
    end
  end

  defp compute_event_id(%{"pubkey" => pubkey, "created_at" => created_at, "kind" => kind, "tags" => tags, "content" => content}) do
    canonical_json = [
      0,
      pubkey,
      created_at,
      kind,
      tags,
      content
    ]

    canonical_json
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

