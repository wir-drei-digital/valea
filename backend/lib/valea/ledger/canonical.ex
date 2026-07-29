defmodule Valea.Ledger.Canonical do
  @moduledoc """
  Content identity for ledger values: a key-sorted JSON encoding and its
  SHA-256 digest.

  Both ledgers need to answer "is this the same content as before?" about maps
  that came out of `Jason.decode/1`, where key order is whatever the decoder
  produced and therefore carries no meaning. The archive uses it as a task
  snapshot's identity (`Valea.Tasks.snapshot_hash/1`, the append-then-prune
  handshake) and the scheduler uses it as a schedule's execution fingerprint
  (`Valea.Schedules.Entry.fingerprint/1`, the anchor-reset trigger) — two
  different questions, one canonical form, so the two can never disagree about
  what "unchanged" means.

  `Jason` has no "sort keys" option, so the object layer is emitted here and
  the leaves go through `Jason.encode!/1` for escaping and number formatting.
  Sorting recurses: nested objects are canonical too, which is what makes a
  reordered `payload` hash the same as the original.
  """

  @doc """
  Lowercase hex SHA-256 over `encode/1` — the identity token itself.
  """
  @spec hash(term()) :: String.t()
  def hash(value), do: :sha256 |> :crypto.hash(encode(value)) |> Base.encode16(case: :lower)

  @doc """
  `value` as key-sorted JSON iodata.

  Keys are compared as strings (atom keys are stringified first), so a map
  mixing the two forms still has one deterministic order.
  """
  @spec encode(term()) :: iodata()
  def encode(list) when is_list(list) do
    ["[", list |> Enum.map(&encode/1) |> Enum.intersperse(","), "]"]
  end

  def encode(map) when is_map(map) and not is_struct(map) do
    inner =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [Jason.encode!(key), ":", encode(value)] end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end

  def encode(scalar), do: Jason.encode!(scalar)
end
