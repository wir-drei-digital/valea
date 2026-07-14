defmodule Valea.ICM.LinkRewrite do
  @moduledoc """
  Rewrites inbound in-content link/image destinations when a page or
  folder is renamed — byte-surgically: only the destination bytes (plus
  `<>` wrapping when the new destination needs it) change; the file is
  never round-tripped through the converter, so the determinism contract
  holds. A destination is only rewritten when it is confirmed, via
  `Valea.ICM.Backlinks.destinations/3` (a real AST parse), to be an actual
  Link/Image node resolving to one of the renamed `pairs`' OLD path — a
  prose mention or a code-fence lookalike is never a Link/Image node, so
  `destinations/3` never reports it, and it is left untouched.

  Addressed by `mount_key` + paths relative to the RENAMED target's own ICM
  root (task 4.2's re-key). SCOPE (Task 5.6, spec decision (b)): source
  pages are scanned across `mount_key`'s own ICM plus every ICM it directly
  declares related via its own `CONTEXT.md` (`Valea.Mounts.scoped_roots/2`)
  — the same session-context boundary the redesign enforces everywhere
  else, matching `Valea.ICM.Backlinks`'s own scope. An inbound link living
  in a DIFFERENT, un-declared ICM that points at a page renamed here is
  still left dangling (by design, not a gap: that ICM is outside the
  session context boundary) — see `confirmed_urls/4` for how a confirmed
  cross-mount source's relative destination is recomputed correctly
  through absolute-path math rather than mount-relative segment math
  (source and target can be in physically unrelated directory trees once
  the source lives in a different ICM than the renamed target).

  Known limitations (two more; neither ever corrupts a file — the worst
  outcome in either case is a link pointing at the wrong-but-plausible
  place):

    * Fence-duplicate rewrite. The splice itself is TEXTUAL, not
      positional — once a destination string is confirmed (by the
      presence of at least one real Link/Image node resolving to the
      renamed target ANYWHERE in the file), every textual occurrence of
      that exact destination string in the file is spliced, in both its
      bracketed (`](<dest>)`) and unbracketed (`](dest)`) forms. If the
      SAME destination string also happens to appear, byte-for-byte,
      inside a code fence or other non-link context IN THE SAME FILE as a
      real, confirmed link to it, that fence occurrence is rewritten too
      — the AST only confirms the file has *a* real link with that
      destination, not which specific textual span it came from. This is
      accepted as a rare, cosmetic edge case (the fence text now names
      the new path instead of the old one — still a plausible, readable
      path string, not corruption). A destination that appears ONLY
      inside a code fence, with no real Link/Image node anywhere in the
      file resolving to the renamed target, is correctly left untouched
      — confirmation fails for the whole file, so no splice is attempted
      at all.

    * Normalize mismatch (dangling, not rewritten — and NOT the only hole
      above). `Backlinks.destinations/3`'s `:url` is MDEx's *normalized*
      destination: HTML entities (`&amp;`, `&#39;`, `&lt;`, …) are
      entity-decoded and backslash escapes (`\_`, `\&`, …) are unescaped
      during parsing. The splice, however, searches the RAW on-disk bytes
      for `](<url>)` / `](url)` built from that normalized string. When a
      confirmed inbound link is WRITTEN in an entity or escaped form —
      e.g. on disk `[x](Foo&amp;Bar.md)`, pointing at a file literally
      named `Foo&Bar.md` — the normalized `:url` (`"Foo&Bar.md"`) never
      occurs as raw bytes in the file (which has `"Foo&amp;Bar.md"`), so
      the splice finds no match and silently skips it: the link is left
      exactly as written, and after the rename it points at a name that
      no longer exists. That is a dangling reference — the same failure
      class as a link that was already dangling before the rename — never
      corrupted bytes; and because nothing on disk changed, the source
      page is correctly absent from `updated_pages`. Likelihood is low:
      it needs BOTH a special-character filename AND a link written in
      entity/backslash form. Valea's own converter always serializes
      destinations with raw characters (see `Valea.Markdown.ProseMirror`),
      so Valea-authored links are never affected by this; the exposure is
      non-Valea-authored markdown living in an external, by-reference
      mount.
  """

  alias Valea.ICM.{Backlinks, Splice}
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  @doc """
  Rewrites every `.md` file IN SCOPE (see moduledoc "SCOPE") whose
  confirmed Link/Image destinations resolve to one of `pairs`' OLD paths,
  replacing each with the recomputed destination for the corresponding NEW
  path. `pairs` are `{old_rel, new_rel}`, both relative to `mount_key`'s
  own root (the RENAMED target's ICM) — the same shape `Valea.ICM.rename/3`
  already works in for its other return fields.

  Returns `{:ok, [updated_source_paths]}` (sorted) on success, or
  `{:error, {:rewrite_failed, file_basename, reason}}` if any write fails —
  mirroring `Valea.ICM.References.rewrite/3`'s contract: already-rewritten
  files are left on disk; the caller surfaces the error. Each
  `updated_source_paths` entry is relative to ITS OWN mount's root — when a
  rewritten source lives in `mount_key`'s own ICM (the common case) that's
  `mount_key`'s root; when it lives in a related ICM instead, it's that
  ICM's own root. KNOWN LIMITATION: this list carries no mount qualifier
  per entry (unlike `Valea.ICM.Backlinks`'s per-item `mount` field), so if
  the SAME relative path happens to exist in `mount_key`'s ICM and in a
  related one and BOTH get rewritten, the two entries in this list are
  textually indistinguishable — a display/informational ambiguity only,
  never a write-correctness one (each file was written to its own real,
  correctly-resolved absolute path). `{:error, :outside_workspace}` when
  `mount_key` doesn't name a currently enabled, non-degraded mount;
  `{:error, :no_workspace}` when no workspace is open.
  """
  @spec rewrite_all(String.t(), [{String.t(), String.t()}]) ::
          {:ok, [String.t()]}
          | {:error, {:rewrite_failed, String.t(), term()} | :outside_workspace | :no_workspace}
  def rewrite_all(mount_key, pairs) do
    with {:ok, mount} <- resolve_mount(mount_key),
         {:ok, workspace} <- workspace_root() do
      sources =
        for scoped <- Mounts.scoped_roots(workspace, mount_key),
            abs <- Path.wildcard(Path.join(scoped.root, "**/*.md")),
            do: {scoped.root, Path.relative_to(abs, scoped.root), abs}

      needles = basename_needles(pairs)

      sources
      |> Enum.reduce_while({:ok, []}, fn {source_root, source_rel, abs}, {:ok, updated} ->
        case rewrite_file(mount.root, source_root, source_rel, abs, pairs, needles) do
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
  end

  # Resolves `mount_key` to its mount via `Mounts.mount_by_key/2`, requiring
  # it to be currently ENABLED and non-degraded — mirrors `Valea.ICM`'s own
  # `resolve_mount/1` (kept local rather than shared: a small,
  # self-contained module).
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

  # Cheap pre-filter mirroring `Backlinks.backlinks/2`'s: a source can only
  # contain a confirmed link to a renamed target if its raw bytes contain
  # that target's basename, either literally or `URI.encode/1`-percent-
  # encoded — skip the AST parse entirely otherwise. This is a pure speed
  # optimization: it never changes which files end up rewritten, because a
  # file that fails this check would have produced no confirmed splice
  # anyway. It also, correctly, pre-filters out the HTML-entity/backslash
  # -escaped case documented above as unrewritable (raw bytes there contain
  # neither the literal nor the percent-encoded basename) — consistent
  # with, not a new instance of, that documented limitation.
  defp basename_needles(pairs) do
    for {old, _new} <- pairs,
        basename = Path.basename(old),
        needle <- [basename, URI.encode(basename)],
        uniq: true,
        do: needle
  end

  defp rewrite_file(target_root, source_root, source_rel, abs, pairs, needles) do
    with {:ok, content} <- File.read(abs) do
      if Enum.any?(needles, &String.contains?(content, &1)) do
        splice_file(target_root, source_root, source_rel, abs, content, pairs)
      else
        :unchanged
      end
    end
  end

  defp splice_file(target_root, source_root, source_rel, abs, content, pairs) do
    confirmed = confirmed_urls(target_root, source_root, source_rel, content, pairs)

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

  # For every (old -> new) pair, this source's confirmed Link/Image
  # destinations (from Backlinks.destinations/3 — a real AST parse) whose
  # RESOLVED absolute path (`:abs`, already percent-decoded) matches the
  # pair's old absolute path (resolved against `target_root` — the RENAMED
  # target's own ICM root, since `pairs` is always in that ICM's
  # vocabulary), are mapped RAW url string (`:url` — the exact on-disk
  # bytes, unbracketed, un-decoded) to its replacement destination string.
  #
  # `source_root` is the SOURCE page's own mount root — the SAME as
  # `target_root` for a same-ICM link (the common case), but a DIFFERENT
  # physical directory tree entirely when the source lives in a related ICM
  # (Task 5.6 scope widening). `Backlinks.destinations/3` is called with
  # `source_root` so its `source_dir` (and therefore every resolved `:abs`)
  # is computed from the file's REAL on-disk location, regardless of which
  # ICM it lives in.
  defp confirmed_urls(target_root, source_root, source_rel, content, pairs) do
    dests = Backlinks.destinations(source_root, source_rel, content)
    source_dir_abs = Path.dirname(to_abs(source_root, source_rel))

    for {old, new} <- pairs,
        old_abs = to_abs(target_root, old),
        new_abs = to_abs(target_root, new),
        %{url: url, abs: abs} <- dests,
        abs == old_abs,
        into: %{} do
      {url, replacement(url, source_dir_abs, new_abs)}
    end
  end

  # Path rule (editor spec): an absolute on-disk destination stays
  # absolute; every other destination is recomputed relative-from-the-
  # linking-page. Both arguments here are already ABSOLUTE, real on-disk
  # paths (never mount-relative strings) — `Valea.Paths.relative/2` is pure
  # segment math (`Path.split/1` + a common-prefix drop), so it needs both
  # sides in the SAME coordinate system to produce a sane result; using
  # absolute paths makes that hold regardless of whether the source page
  # and the renamed target live in the same ICM or in two unrelated
  # directory trees (a related ICM mounted elsewhere on disk entirely).
  # For a same-ICM link this produces byte-identical output to the old
  # mount-relative computation (the shared `target_root`/`source_root`
  # prefix simply drops out of the common-prefix match).
  defp replacement("/" <> _, _source_dir_abs, new_abs), do: new_abs

  defp replacement(_url, source_dir_abs, new_abs),
    do: Valea.Paths.relative(source_dir_abs, new_abs)

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

  defp to_abs(_mount_root, "/" <> _ = abs), do: Path.expand(abs)
  defp to_abs(mount_root, rel), do: Path.expand(rel, mount_root)
end
