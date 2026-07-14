defmodule Valea.ICM.References do
  @moduledoc """
  Finds and rewrites workflow references to ICM pages/folders — scoped to a
  single ICM, addressed by `mount_key` + a path relative to that ICM's own
  root (task 4.2's re-key).

  A workflow page's `sources:` frontmatter references ICM content via a
  literal, ICM-relative path string: `<inner>`, relative to the referencing
  workflow's OWN mount root (a workflow in `Workflows/` points at a page
  via `Offers/X.md`). `referencing_workflows/2` and `rewrite/3` both take
  `mount_key` + that `<inner>` path directly and scan/rewrite only that
  mount's `Workflows/*.md` files for the needle — a same-named page in a
  different mount is never matched (mount isolation is by directory, not by
  the needle string), and a rename can never cross mounts (there is only
  one `mount_key` argument to give it).

  Workflow pages are treated as opaque text here — scanning/rewriting by
  substring is both simpler and more robust than parsing YAML and chasing
  its structure. But a bare substring is not enough: the needle
  `Offers/X.md` also occurs inside the longer paths `Special Offers/X.md`
  and `MoreOffers/X.md`, so every occurrence is anchored by the character
  immediately before it:

    * start of content, a newline, or an opening delimiter
      (`"`, `'`, `(`, `[`, `` ` ``) — a real reference boundary; match.
    * space/tab — ambiguous, because ICM paths may contain spaces: the
      text is extended left — to the nearest opening delimiter/newline,
      then (since an opener can itself appear inside a path name,
      `Lea's Notes/X.md`) past each further delimiter up to the start of
      the line — and every successively longer candidate is probed for
      existence under the mount root, a `<folder>/*` wildcard candidate
      probing the folder itself. If ANY candidate is a DIFFERENT existing
      path (`Special Offers/X.md`, `My Clients/*`), the occurrence
      belongs to that longer path and is skipped; otherwise it is a match
      (`- Offers/X.md` YAML list items, prose mentions).
    * anything else (letters, digits, `/`, `-`, `.`, …) — the occurrence
      is the tail of a longer token (`MoreOffers/X.md`, `Sub/Offers/X.md`);
      skipped.

  Known limitation of existence-based disambiguation: a DANGLING superset
  reference — `"Special Offers/X.md"` where that longer path is no longer
  on disk — fails every probe, so renaming `Offers/X.md` rewrites its
  tail. Renames keep references coherent for content that exists;
  already-dangling references were already broken and stay broken (now
  with a renamed tail).

  The same anchored matching drives both detection and replacement, so
  `rewrite/3` never touches an occurrence `referencing_workflows/2` would
  not report.
  """

  alias Valea.ICM.Splice
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  @name_regex ~r/^name:\s*(.+)$/m

  # Characters that open a quoted/bracketed reference — a needle occurrence
  # directly after one of these is a real reference boundary. Also the hard
  # stops (together with a newline) when extending an ambiguous
  # space-preceded occurrence leftward.
  @boundary_openers [?", ?', ?(, ?[, ?`]

  @doc """
  Lists the workflows — within `mount_key`'s own ICM — that reference
  `rel_path`, by scanning every `{mount_root}/Workflows/*.md` for the
  ICM-relative needle, anchored per the moduledoc's boundary rules.

  Returns `{:ok, [%{file: filename, name: display_name}]}`, sorted by
  filename. `display_name` is read from a top-level `name:` line in the
  page (a legacy YAML convention), falling back to the filename without
  its extension when absent — which is every current page, since the
  frontmatter carries no `name:` key.

  Errors: `{:error, :invalid_path}` when `rel_path` is the bare mount root
  (`""` — an empty needle would match everything); `{:error,
  :outside_workspace}` when `mount_key` doesn't name a currently enabled,
  non-degraded mount; `{:error, :no_workspace}` when no workspace is open.
  """
  def referencing_workflows(mount_key, rel_path) do
    with {:ok, mount} <- resolve_mount(mount_key),
         {:ok, needle} <- inner_needle(rel_path) do
      refs =
        mount
        |> workflows_dir()
        |> workflow_files()
        |> Enum.filter(fn abs -> anchored_matches(File.read!(abs), needle, mount.root) != [] end)
        |> Enum.map(&describe_workflow/1)
        |> Enum.sort_by(& &1.file)

      {:ok, refs}
    end
  end

  @doc """
  Rewrites every workflow — within `mount_key`'s own ICM — referencing
  `old_rel` to reference `new_rel` instead, by replacing each anchored
  occurrence of the old `<inner>` needle (same boundary rules as
  `referencing_workflows/2`) and atomically writing the file back.

  `old_rel` and `new_rel` are both relative to `mount_key`'s own root.

  Returns `{:ok, [updated_filenames]}` (sorted) on success,
  `{:error, :invalid_path}` when either path is the bare mount root,
  `{:error, :outside_workspace}` / `{:error, :no_workspace}` from mount
  resolution, or `{:error, {:rewrite_failed, file_basename, reason}}` if
  any write fails.

  Note: A rewrite failure leaves already-rewritten files on disk; the caller
  must surface the error to the user (who can decide whether to retry, rollback
  via version control, or manually intervene).
  """
  def rewrite(mount_key, old_rel, new_rel) do
    with {:ok, mount} <- resolve_mount(mount_key),
         {:ok, old_needle} <- inner_needle(old_rel),
         {:ok, new_needle} <- inner_needle(new_rel) do
      files_to_rewrite =
        mount
        |> workflows_dir()
        |> workflow_files()
        |> Enum.map(fn abs ->
          content = File.read!(abs)
          {abs, content, anchored_matches(content, old_needle, mount.root)}
        end)
        |> Enum.reject(fn {_abs, _content, matches} -> matches == [] end)

      rewrite_all(files_to_rewrite, new_needle)
    end
  end

  # Resolves `mount_key` to its mount via `Mounts.mount_by_key/2`, requiring
  # it to be currently ENABLED and non-degraded — mirrors `Valea.ICM`'s own
  # `resolve_mount/1` (kept local rather than shared for the same reason
  # `atomic_write/2` below is: a small, self-contained module).
  defp resolve_mount(mount_key) do
    with {:ok, ws} <- workspace_root() do
      case Mounts.mount_by_key(ws, mount_key) do
        %{enabled: true, degraded: nil} = mount -> {:ok, mount}
        _ -> {:error, :outside_workspace}
      end
    end
  end

  defp workspace_root do
    case Manager.current() do
      {:ok, %{path: ws}} -> {:ok, ws}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  # `rel_path` IS the search/replace needle now (already ICM-relative — no
  # more `mounts/<name>` prefix to strip). A bare mount root (`""`) is
  # invalid: an empty needle would match everywhere and a replace with/of
  # "" shreds files.
  defp inner_needle(""), do: {:error, :invalid_path}
  defp inner_needle(rel_path), do: {:ok, rel_path}

  # -- anchored matching (shared by detection and replacement) -----------

  # All `{byte_pos, byte_len}` occurrences of `needle` in `content` that
  # pass the boundary rules (see moduledoc). Byte-level inspection of the
  # preceding character is UTF-8 safe: the anchor characters are all ASCII,
  # and an ASCII byte value never occurs inside a multi-byte UTF-8
  # sequence — a trailing byte of a multi-byte character falls through to
  # the token-continuation (skip) clause, which is the correct call.
  defp anchored_matches(content, needle, mount_root) do
    content
    |> :binary.matches(needle)
    |> Enum.filter(&anchored?(content, &1, needle, mount_root))
  end

  defp anchored?(_content, {0, _len}, _needle, _mount_root), do: true

  defp anchored?(content, {pos, _len}, needle, mount_root) do
    case :binary.at(content, pos - 1) do
      ?\n ->
        true

      prev when prev in @boundary_openers ->
        true

      prev when prev in [?\s, ?\t] ->
        not longer_existing_path?(content, pos, needle, mount_root)

      _token_continuation ->
        false
    end
  end

  # A space-preceded occurrence is ambiguous — ICM paths may contain
  # spaces, so `Offers/X.md` inside `"Special Offers/X.md"` is the tail of
  # a longer path, while `- Offers/X.md` (YAML list item) or a prose
  # mention is a genuine reference. Disambiguate by extending the text
  # leftward and probing each successively longer candidate (extension +
  # needle, leading whitespace trimmed) for existence under the mount
  # root: if ANY candidate is a different, existing path, the occurrence
  # belongs to that longer path — skip it. A single extension to the
  # nearest delimiter is not enough, because an opening delimiter can
  # itself appear inside a path name (`Lea's Notes/X.md` — the `'` would
  # truncate the candidate to the nonexistent `s Notes/X.md`), so the
  # search keeps extending past each delimiter up to the start of the
  # line before declaring the occurrence genuine.
  defp longer_existing_path?(content, pos, needle, mount_root) do
    content
    |> extension_bounds(pos)
    |> Enum.any?(fn bound ->
      extension = binary_part(content, bound, pos - bound)
      candidate = String.trim_leading(extension) <> needle
      candidate != needle and existing_path?(mount_root, candidate)
    end)
  end

  # The candidate left-extension bounds for an ambiguous occurrence at
  # `pos`: the position just after each opening delimiter scanning
  # leftward, nearest first, ending with the start of the line (or of the
  # content).
  defp extension_bounds(content, pos), do: collect_bounds(content, pos - 1, [])

  defp collect_bounds(_content, i, acc) when i < 0, do: Enum.reverse([0 | acc])

  defp collect_bounds(content, i, acc) do
    case :binary.at(content, i) do
      ?\n -> Enum.reverse([i + 1 | acc])
      c when c in @boundary_openers -> collect_bounds(content, i - 1, [i + 1 | acc])
      _ -> collect_bounds(content, i - 1, acc)
    end
  end

  # Existence probe for a candidate longer path. A wildcard reference
  # (`<folder>/*` — the needle shape folder renames emit, see
  # `Valea.ICM.rename/3`) can never exist as a literal file, so the folder
  # itself is probed instead.
  defp existing_path?(mount_root, candidate) do
    if String.ends_with?(candidate, "/*") do
      folder = binary_part(candidate, 0, byte_size(candidate) - 2)
      File.dir?(Path.join(mount_root, folder))
    else
      File.exists?(Path.join(mount_root, candidate))
    end
  end

  defp rewrite_all(files, new_needle) do
    result =
      Enum.reduce_while(files, {:ok, []}, fn {abs, content, matches}, {:ok, updated} ->
        rewritten = Splice.splice(content, matches, new_needle)

        case atomic_write(abs, rewritten) do
          :ok ->
            {:cont, {:ok, [Path.basename(abs) | updated]}}

          {:error, reason} ->
            {:halt, {:error, {:rewrite_failed, Path.basename(abs), reason}}}
        end
      end)

    case result do
      {:ok, updated} -> {:ok, Enum.sort(updated)}
      error -> error
    end
  end

  defp workflows_dir(mount), do: Path.join(mount.root, "Workflows")

  defp workflow_files(dir) do
    dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp describe_workflow(abs) do
    content = File.read!(abs)

    name =
      case Regex.run(@name_regex, content) do
        [_, captured] -> String.trim(captured)
        nil -> abs |> Path.basename() |> Path.rootname()
      end

    %{file: Path.basename(abs), name: name}
  end

  # Mirrors the private atomic_write in Valea.ICM (write to a `.tmp` sibling,
  # then rename over the target) — kept local rather than shared because
  # References is a small, self-contained module and the pattern is two
  # lines; not worth a shared dependency for.
  defp atomic_write(abs, bytes) do
    tmp = abs <> ".tmp"

    with :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, abs) do
      :ok
    end
  end
end
