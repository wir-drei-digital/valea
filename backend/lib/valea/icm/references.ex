defmodule Valea.ICM.References do
  @moduledoc """
  Finds and rewrites workflow references to ICM pages/folders — scoped to a
  single mount.

  A workflow page's `sources:` frontmatter references ICM content via a
  literal, ICM-relative path string: `<inner>`, relative to the referencing
  workflow's OWN mount root (a workflow in `mounts/primary/Workflows/`
  points at a page via `Offers/X.md`, never `mounts/primary/Offers/X.md`).
  `referencing_workflows/1` and `rewrite/2` both take a workspace-relative
  `mounts/<name>/<inner>` path, resolve the owning mount via
  `Valea.Mounts.mount_for/1`, and scan/rewrite only THAT mount's
  `Workflows/*.md` files for the `<inner>` needle — a same-named page in a
  different mount is never matched (mount isolation is by directory, not by
  the needle string).

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
  `rewrite/2` never touches an occurrence `referencing_workflows/1` would
  not report.
  """

  alias Valea.Mounts

  @name_regex ~r/^name:\s*(.+)$/m

  # Characters that open a quoted/bracketed reference — a needle occurrence
  # directly after one of these is a real reference boundary. Also the hard
  # stops (together with a newline) when extending an ambiguous
  # space-preceded occurrence leftward.
  @boundary_openers [?", ?', ?(, ?[, ?`]

  @doc """
  Lists the workflows — within `rel_path`'s own mount — that reference it,
  by scanning every `{mount_root}/Workflows/*.md` for the ICM-relative
  needle, anchored per the moduledoc's boundary rules.

  `rel_path` is workspace-relative (`mounts/<name>/<inner>`); the string
  scanned for is `<inner>` alone (no `mounts/<name>` prefix).

  Returns `{:ok, [%{file: filename, name: display_name}]}`, sorted by
  filename. `display_name` is read from a top-level `name:` line in the
  page (a legacy YAML convention), falling back to the filename without
  its extension when absent — which is every current page, since the
  frontmatter carries no `name:` key.

  Errors: `{:error, :invalid_path}` when `rel_path` is a bare mount root
  (empty inner path — an empty needle would match everything);
  `{:error, :outside_workspace}` when `rel_path` doesn't name a mount
  discovered in the current workspace; `{:error, :no_workspace}` when no
  workspace is open.
  """
  def referencing_workflows(rel_path) do
    with {:ok, mount} <- resolve_mount(rel_path),
         {:ok, needle} <- inner_needle(rel_path, mount) do
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
  Rewrites every workflow — within `old_rel`'s mount — referencing
  `old_rel` to reference `new_rel` instead, by replacing each anchored
  occurrence of the old `<inner>` needle (same boundary rules as
  `referencing_workflows/1`) and atomically writing the file back.

  `old_rel` and `new_rel` are both workspace-relative (`mounts/<name>/<inner>`)
  and MUST name the same mount — a rename never crosses mounts.

  Returns `{:ok, [updated_filenames]}` (sorted) on success,
  `{:error, :cross_mount_rename}` when `old_rel`/`new_rel` name different
  mounts, `{:error, :invalid_path}` when either path is a bare mount root,
  `{:error, :outside_workspace}` / `{:error, :no_workspace}` from mount
  resolution, or `{:error, {:rewrite_failed, file_basename, reason}}` if
  any write fails.

  Note: A rewrite failure leaves already-rewritten files on disk; the caller
  must surface the error to the user (who can decide whether to retry, rollback
  via version control, or manually intervene).
  """
  def rewrite(old_rel, new_rel) do
    with {:ok, old_mount} <- resolve_mount(old_rel),
         {:ok, new_mount} <- resolve_mount(new_rel),
         :ok <- same_mount(old_mount, new_mount),
         {:ok, old_needle} <- inner_needle(old_rel, old_mount),
         {:ok, new_needle} <- inner_needle(new_rel, new_mount) do
      files_to_rewrite =
        old_mount
        |> workflows_dir()
        |> workflow_files()
        |> Enum.map(fn abs ->
          content = File.read!(abs)
          {abs, content, anchored_matches(content, old_needle, old_mount.root)}
        end)
        |> Enum.reject(fn {_abs, _content, matches} -> matches == [] end)

      rewrite_all(files_to_rewrite, new_needle)
    end
  end

  defp same_mount(%{name: name}, %{name: name}), do: :ok
  defp same_mount(_old_mount, _new_mount), do: {:error, :cross_mount_rename}

  # `Mounts.mount_for/1` is attribution-only (per its own docs): it names
  # the mount `rel_path` points into without validating the rest of the
  # path. That is exactly what this module needs — it never turns
  # `rel_path` into a filesystem path itself, only strips its `mounts/<name>`
  # prefix to build a search/replace needle (see `inner_needle/1`); the
  # scan/rewrite I/O is confined to `mount.root/Workflows/*.md` by
  # construction via `workflow_files/1`'s glob, and the ambiguity probe in
  # `longer_existing_path?/4` is a read-only `File.exists?`.
  defp resolve_mount(rel_path) do
    case Mounts.mount_for(rel_path) do
      {:ok, mount} -> {:ok, mount}
      {:error, :not_in_mount} -> {:error, :outside_workspace}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  # The mount-relative inner path is the search/replace needle. A bare
  # mount root (inner path "") is invalid: an empty needle would match
  # everywhere and a replace with/of "" shreds files.
  defp inner_needle(rel_path, mount) do
    case mount_relative(rel_path, mount) do
      "" -> {:error, :invalid_path}
      needle -> {:ok, needle}
    end
  end

  # The path relative to `mount`'s OWN root — ICM-relative to that mount.
  # Mirrors the private `mount_relative/2` in `Valea.ICM` — kept local
  # rather than shared for the same reason `atomic_write/2` below is: a
  # small, self-contained module, not worth a shared dependency for.
  #
  #   * embedded: strips the leading `mounts/<name>` segment off the
  #     workspace-relative `rel_path`.
  #   * external (A2-T5b, `rel_root: nil`): strips `mount.root` itself off
  #     the ABSOLUTE `rel_path`.
  defp mount_relative(rel_path, %{rel_root: nil, root: root}) do
    cond do
      rel_path == root -> ""
      String.starts_with?(rel_path, root <> "/") -> String.trim_leading(rel_path, root <> "/")
      true -> rel_path
    end
  end

  defp mount_relative(rel_path, _mount) do
    case Path.split(rel_path) do
      ["mounts", _name | rest] -> Enum.join(rest, "/")
      _ -> rel_path
    end
  end

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
  # `Valea.ICM.rename/2`) can never exist as a literal file, so the folder
  # itself is probed instead.
  defp existing_path?(mount_root, candidate) do
    if String.ends_with?(candidate, "/*") do
      folder = binary_part(candidate, 0, byte_size(candidate) - 2)
      File.dir?(Path.join(mount_root, folder))
    else
      File.exists?(Path.join(mount_root, candidate))
    end
  end

  # Splices `replacement` over each matched range, right-to-left so the
  # byte offsets of the earlier (unprocessed) matches stay valid while the
  # binary grows/shrinks behind them.
  defp splice(content, matches, replacement) do
    matches
    |> Enum.sort_by(fn {pos, _len} -> pos end, :desc)
    |> Enum.reduce(content, fn {pos, len}, acc ->
      prefix = binary_part(acc, 0, pos)
      suffix = binary_part(acc, pos + len, byte_size(acc) - pos - len)
      prefix <> replacement <> suffix
    end)
  end

  defp rewrite_all(files, new_needle) do
    result =
      Enum.reduce_while(files, {:ok, []}, fn {abs, content, matches}, {:ok, updated} ->
        rewritten = splice(content, matches, new_needle)

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
