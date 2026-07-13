defmodule Valea.Paths do
  @moduledoc """
  Symlink-aware containment with realpath semantics. The ICM chokepoint's
  lexical check is not enough for the agent boundary: a symlink inside the
  workspace can point anywhere.

  `resolve_real/2` resolves `path` against `base` the way the OS does —
  symlinks are resolved BEFORE any following `..` is applied. It walks the
  path components left-to-right from the resolved base:

    * a normal component is appended, then if the result is a symlink its
      target is resolved against the symlink's PHYSICAL parent (absolute
      targets replace the accumulator, relative ones join to it);
    * `..` pops the accumulator to its PHYSICAL parent — the parent of what
      has actually been resolved so far, NOT a lexical stack pop, so a
      symlink followed by `..` lands in the symlink target's real parent;
    * `.` is skipped;
    * once a component does not exist the remainder cannot contain symlinks,
      so it is appended literally — but any `..` in that remainder is still
      applied physically against the resolved-so-far parent.

  Symlink resolution is bounded to 32 hops across the whole walk. Only after
  the physical path is fully resolved is it checked for containment in the
  (also symlink-resolved) `base`.
  """

  @max_hops 32

  @doc """
  Lexical relative path from `from_dir` to `to_path` (same vocabulary on
  both sides — both workspace-relative, or both absolute physical paths).
  Pure segment math — no filesystem access, no symlink resolution: drops
  the common leading path segments, then emits one `".."` per remaining
  `from_dir` segment, joined with the remaining `to_path` segments.
  """
  @spec relative(String.t(), String.t()) :: String.t()
  def relative(from_dir, to_path) do
    from = Path.split(from_dir)
    to = Path.split(to_path)
    {common_from, common_to} = drop_common(from, to)
    Path.join(List.duplicate("..", length(common_from)) ++ common_to)
  end

  defp drop_common([h | t1], [h | t2]), do: drop_common(t1, t2)
  defp drop_common(from, to), do: {from, to}

  @spec resolve_real(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :outside | :invalid}
  def resolve_real(path, base) do
    base_real = resolve_fully(Path.expand(base), @max_hops)
    {start, components} = start_and_components(path, base_real)

    with {:ok, resolved, _hops} <- walk(start, components, @max_hops),
         true <- contained?(resolved, base_real) do
      {:ok, resolved}
    else
      false -> {:error, :outside}
      {:error, _} = err -> err
    end
  end

  # Honour the leading-"/" absoluteness contract: an absolute path starts
  # from the filesystem root, a relative one from the resolved base.
  defp start_and_components(path, base_real) do
    if String.starts_with?(path, "/") do
      {"/", tl(Path.split(path))}
    else
      {base_real, Path.split(path)}
    end
  end

  # Fully resolve an already-absolute path (used for the base) via the same
  # physical walk, falling back to the input if it cannot be resolved.
  defp resolve_fully(abs_path, hops) do
    case walk("/", tl(Path.split(abs_path)), hops) do
      {:ok, resolved, _hops} -> resolved
      {:error, _} -> abs_path
    end
  end

  # Walk components left-to-right maintaining `acc`, the physically-resolved
  # path so far. `hops` is the remaining symlink budget shared across the
  # whole walk (including nested target resolution).
  defp walk(acc, [], hops), do: {:ok, acc, hops}

  defp walk(acc, ["." | rest], hops), do: walk(acc, rest, hops)

  # Physical parent pop: `..` applies to what we have actually resolved, so a
  # preceding symlink has already redirected `acc` to its real location.
  defp walk(acc, [".." | rest], hops), do: walk(Path.dirname(acc), rest, hops)

  defp walk(acc, [comp | rest], hops) do
    candidate = Path.join(acc, comp)

    case File.read_link(candidate) do
      # A symlink (existing or dangling) — resolve it against its physical
      # parent, `acc`, before continuing with the remainder.
      {:ok, _target} when hops <= 0 ->
        {:error, :invalid}

      {:ok, target} ->
        with {:ok, resolved, hops2} <- resolve_target(target, acc, hops - 1) do
          walk(resolved, rest, hops2)
        end

      # Not a symlink (a real file/dir, or a non-existent component). Append
      # literally; a non-existent remainder still gets its `..` popped
      # physically by the clauses above.
      {:error, _} ->
        walk(candidate, rest, hops)
    end
  end

  # Resolve a symlink target: absolute targets restart from root, relative
  # targets join to the symlink's physical parent. The target path is itself
  # walked so any symlinks/`..` inside it resolve physically too.
  defp resolve_target(target, parent, hops) do
    {start, components} =
      if String.starts_with?(target, "/") do
        {"/", tl(Path.split(target))}
      else
        {parent, Path.split(target)}
      end

    walk(start, components, hops)
  end

  defp contained?(resolved, base_real) do
    resolved == base_real or String.starts_with?(resolved <> "/", base_real <> "/")
  end
end
