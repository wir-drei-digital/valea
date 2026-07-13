defmodule Valea.ICM.LinkRewrite do
  @moduledoc """
  Rewrites inbound in-content link/image destinations when a page or
  folder is renamed — byte-surgically: only the destination bytes (plus
  `<>` wrapping when the new destination needs it) change; the file is
  never round-tripped through the converter, so the determinism contract
  holds. A destination is only rewritten when it is confirmed, via
  `Valea.ICM.Backlinks.destinations/3` (a real AST parse), to be an actual
  Link/Image node resolving to one of the renamed `pairs`' OLD absolute
  path — a prose mention or a code-fence lookalike is never a Link/Image
  node, so `destinations/3` never reports it, and it is left untouched.

  Known limitation: the splice itself is TEXTUAL, not positional — once a
  destination string is confirmed (by the presence of at least one real
  Link/Image node resolving to the renamed target ANYWHERE in the file),
  every textual occurrence of that exact destination string in the file
  is spliced, in both its bracketed (`](<dest>)`) and unbracketed
  (`](dest)`) forms. If the SAME destination string also happens to
  appear, byte-for-byte, inside a code fence or other non-link context IN
  THE SAME FILE as a real, confirmed link to it, that fence occurrence is
  rewritten too — the AST only confirms the file has *a* real link with
  that destination, not which specific textual span it came from. This is
  accepted as a rare, cosmetic edge case (the fence text now names the new
  path instead of the old one — still a plausible, readable path string,
  not corruption). A destination that appears ONLY inside a code fence,
  with no real Link/Image node anywhere in the file resolving to the
  renamed target, is correctly left untouched — confirmation fails for
  the whole file, so no splice is attempted at all.
  """

  alias Valea.ICM.{Backlinks, Splice}
  alias Valea.Mounts

  @doc """
  Rewrites every enabled mount's `.md` files whose confirmed Link/Image
  destinations resolve to one of `pairs`' OLD absolute paths, replacing
  each with the recomputed destination for the corresponding NEW path.
  `pairs` are `{old_path, new_path}` in TREE VOCABULARY (workspace-relative
  `mounts/<name>/…` for an embedded path, absolute for an external one) —
  the same shape `Valea.ICM.rename/2` already works in for its other
  return fields.

  Returns `{:ok, [updated_source_paths]}` (sorted, tree vocabulary) on
  success, or `{:error, {:rewrite_failed, file_basename, reason}}` if any
  write fails — mirroring `Valea.ICM.References.rewrite/2`'s contract:
  already-rewritten files are left on disk; the caller surfaces the error.
  """
  @spec rewrite_all(String.t(), [{String.t(), String.t()}]) ::
          {:ok, [String.t()]} | {:error, {:rewrite_failed, String.t(), term()}}
  def rewrite_all(workspace, pairs) do
    sources =
      for mount <- Mounts.enabled(workspace),
          root = mount_root(workspace, mount),
          prefix = mount.rel_root || mount.root,
          abs <- Path.wildcard(Path.join(root, "**/*.md")),
          do: {Path.join(prefix, Path.relative_to(abs, root)), abs}

    Enum.reduce_while(sources, {:ok, []}, fn {source_rel, abs}, {:ok, updated} ->
      case rewrite_file(workspace, source_rel, abs, pairs) do
        :unchanged -> {:cont, {:ok, updated}}
        {:ok, _} -> {:cont, {:ok, [source_rel | updated]}}
        {:error, reason} -> {:halt, {:error, {:rewrite_failed, Path.basename(abs), reason}}}
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, Enum.sort(updated)}
      err -> err
    end
  end

  defp rewrite_file(workspace, source_rel, abs, pairs) do
    with {:ok, content} <- File.read(abs) do
      confirmed = confirmed_urls(workspace, source_rel, content, pairs)

      case splice_urls(content, confirmed) do
        ^content ->
          :unchanged

        new_content ->
          case atomic_write(abs, new_content) do
            :ok -> {:ok, source_rel}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  # For every (old -> new) pair, this source's confirmed Link/Image
  # destinations (from Backlinks.destinations/3 — a real AST parse) whose
  # RESOLVED absolute path (`:abs`, already percent-decoded) matches the
  # pair's old absolute path, are mapped RAW url string (`:url` — the
  # exact on-disk bytes, unbracketed, un-decoded) to its replacement
  # destination string.
  defp confirmed_urls(workspace, source_rel, content, pairs) do
    dests = Backlinks.destinations(workspace, source_rel, content)
    source_dir = Path.dirname(source_rel)

    for {old, new} <- pairs,
        old_abs = to_abs(workspace, old),
        %{url: url, abs: abs} <- dests,
        abs == old_abs,
        into: %{} do
      {url, replacement(url, source_dir, new, workspace)}
    end
  end

  # Path rule (editor spec): an absolute on-disk destination (either end in
  # an external mount) stays absolute; every other destination is recomputed
  # relative-from-the-linking-page, in the SAME vocabulary `new` is already
  # in (tree vocabulary — `Valea.Paths.relative/2` is pure segment math, no
  # filesystem access, so both sides must already agree on vocabulary).
  defp replacement("/" <> _, _source_dir, new, workspace), do: to_abs(workspace, new)
  defp replacement(_url, source_dir, new, _workspace), do: Valea.Paths.relative(source_dir, new)

  # Replaces each confirmed url's occurrences INSIDE link-closing syntax
  # only — `](url)` / `](<url>)` (an image `![alt](` ends with the same
  # `](`) — never a bare mention of the url text outside that syntax.
  defp splice_urls(content, confirmed) do
    Enum.reduce(confirmed, content, fn {url, new_dest}, acc ->
      acc
      |> splice_form("](<" <> url <> ">)", "](<" <> new_dest <> ">)")
      |> splice_form("](" <> url <> ")", "](" <> wrap(new_dest) <> ")")
    end)
  end

  defp splice_form(content, old_frag, new_frag) do
    case :binary.matches(content, old_frag) do
      [] -> content
      matches -> Splice.splice(content, matches, new_frag)
    end
  end

  defp wrap(dest), do: if(String.contains?(dest, " "), do: "<" <> dest <> ">", else: dest)

  defp atomic_write(abs, bytes) do
    tmp = abs <> ".tmp"
    with :ok <- File.write(tmp, bytes), do: File.rename(tmp, abs)
  end

  defp mount_root(workspace, %{rel_root: rel}) when is_binary(rel), do: Path.join(workspace, rel)
  defp mount_root(_workspace, %{root: root}), do: root

  defp to_abs(_workspace, "/" <> _ = abs), do: Path.expand(abs)
  defp to_abs(workspace, rel), do: Path.expand(rel, workspace)
end
