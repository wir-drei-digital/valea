defmodule Valea.Paths do
  @moduledoc """
  Symlink-aware containment. The ICM chokepoint's lexical check is not
  enough for the agent boundary: a symlink inside the workspace can point
  anywhere. Resolution walks existing components via `File.read_link`,
  bounded to 32 hops.

  `resolve_real/2` expands `path` against `base`, resolves every symlink
  (leaf AND mid-path directories), and only then verifies the result is
  contained in the (also symlink-resolved) `base`. Non-existent trailing
  components are allowed so a write target that does not exist yet can be
  vetted — but that non-existent remainder must not contain `..`.
  """

  @max_hops 32

  @spec resolve_real(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :outside | :invalid}
  def resolve_real(path, base) do
    abs = Path.expand(path, base)
    base_real = resolve_existing(Path.expand(base), @max_hops)

    with {:ok, resolved} <- split_and_resolve(abs),
         true <-
           String.starts_with?(resolved <> "/", base_real <> "/") or resolved == base_real do
      {:ok, resolved}
    else
      false -> {:error, :outside}
      {:error, _} = err -> err
    end
  end

  # Resolve the deepest existing ancestor; re-append the non-existent tail.
  defp split_and_resolve(abs) do
    {existing, tail} = deepest_existing(abs, [])

    if Enum.any?(tail, &(&1 == "..")) do
      {:error, :invalid}
    else
      {:ok, Path.join([resolve_existing(existing, @max_hops) | tail])}
    end
  end

  # A symlink counts as "existing" even when its target is missing (a broken
  # symlink is still a link we must resolve to catch an escape), so probe
  # `read_link` alongside `exists?` (which follows the link and would miss it).
  defp deepest_existing(path, tail) do
    cond do
      path == "/" -> {path, tail}
      File.exists?(path) or match?({:ok, _}, File.read_link(path)) -> {path, tail}
      true -> deepest_existing(Path.dirname(path), [Path.basename(path) | tail])
    end
  end

  defp resolve_existing(path, 0), do: path

  defp resolve_existing(path, hops) do
    parts = Path.split(path)

    {resolved, _} =
      Enum.reduce(parts, {"", hops}, fn part, {acc, h} ->
        candidate = if acc == "", do: part, else: Path.join(acc, part)

        case File.read_link(candidate) do
          {:ok, target} when h > 0 ->
            target = Path.expand(target, Path.dirname(candidate))
            {resolve_existing(target, h - 1), h - 1}

          _ ->
            {candidate, h}
        end
      end)

    resolved
  end
end
