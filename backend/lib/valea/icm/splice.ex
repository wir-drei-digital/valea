defmodule Valea.ICM.Splice do
  @moduledoc false

  # Splices `replacement` over each `{pos, len}` match in `content`,
  # right-to-left so the byte offsets of the earlier (unprocessed) matches
  # stay valid while the binary grows/shrinks behind them. Extracted
  # verbatim from `Valea.ICM.References` (which now delegates here) so
  # `Valea.ICM.LinkRewrite` can reuse the same right-to-left splice
  # mechanics without duplicating them.
  @spec splice(binary(), [{non_neg_integer(), non_neg_integer()}], binary()) :: binary()
  def splice(content, matches, replacement) do
    matches
    |> Enum.sort_by(fn {pos, _len} -> pos end, :desc)
    |> Enum.reduce(content, fn {pos, len}, acc ->
      prefix = binary_part(acc, 0, pos)
      suffix = binary_part(acc, pos + len, byte_size(acc) - pos - len)
      prefix <> replacement <> suffix
    end)
  end
end
