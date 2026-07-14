defmodule Valea.ICM.Search do
  @moduledoc """
  Scan-backed full-text search. The filesystem is the index (Spec C): per
  query, every mount IN SCOPE is walked concurrently with a hard per-mount
  budget; a mount that does not answer in time is skipped and NAMED, never
  silently dropped. Query text is literal — terms are matched with
  `String.contains?/2` on downcased text, no pattern syntax. The RPC
  contract (`search/4`'s return shape) is deliberately
  implementation-agnostic: FTS5 can replace these internals later.

  Scope (Task 5.6, spec decision (b)): a `mount_key` narrows the scan to
  exactly that ICM plus every ICM it directly declares related via its own
  `CONTEXT.md` (`Valea.Mounts.scoped_roots/2`) — the same session-context
  boundary the redesign enforces everywhere else, so a search from within
  ICM A never surfaces a hit from an unrelated mounted ICM B. `mount_key ==
  nil` preserves the pre-5.6 default of scanning every ENABLED mount (the
  global Cmd+K palette is not yet ICM-scoped — full wiring is a later
  task); an unknown/disabled/degraded `mount_key` scopes to nothing
  (`Mounts.scoped_roots/2` returns `[]`), so search degrades to zero
  results rather than erroring.

  Each result's `path` (task 4.2's re-key) is relative to ITS OWN mount's
  root — paired with `mount` (that mount's key) to fully address it,
  mirroring every other ICM RPC surface's `(mount_key, rel_path)`
  addressing. There is no more embedded-vs-external prefix to compute
  (every mount is external post-3.2 — `Valea.Mounts`'s `rel_root` is
  always `nil`), so this scans each mount's OWN root directly.
  """

  alias Valea.Mounts

  @default_timeout 500
  @default_limit 20
  @snippet_radius 90

  @spec search(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, %{results: [map()], skipped: [String.t()]}}
  def search(workspace, query, mount_key \\ nil, opts \\ []) do
    terms =
      query |> String.downcase() |> String.split(~r/\s+/u, trim: true) |> Enum.uniq()

    if terms == [] do
      {:ok, %{results: [], skipped: []}}
    else
      mounts = Keyword.get_lazy(opts, :mounts, fn -> scan_scope(workspace, mount_key) end)
      timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
      limit = Keyword.get(opts, :limit, @default_limit)

      {hits, skipped} = scan_mounts(workspace, mounts, terms, timeout)

      results =
        hits
        |> Enum.sort_by(fn r -> {-r.score, r.path} end)
        |> Enum.take(limit)
        |> Enum.map(&Map.drop(&1, [:score]))

      {:ok, %{results: results, skipped: skipped}}
    end
  end

  # See moduledoc "Scope" — `nil` means "every enabled mount" (pre-5.6
  # default, still used by the not-yet-ICM-scoped global palette); a
  # concrete `mount_key` narrows to `Mounts.scoped_roots/2`'s primary +
  # declared-related set.
  defp scan_scope(workspace, nil), do: Mounts.enabled(workspace)
  defp scan_scope(workspace, mount_key), do: Mounts.scoped_roots(workspace, mount_key)

  # A single shared deadline for the whole scan: `Task.yield_many/2` blocks
  # at most `timeout` total (not per task), so N slow mounts still return in
  # roughly `timeout` wall time instead of compounding to N * timeout. Any
  # mount not finished when the shared deadline elapses is shut down and
  # named in `skipped`. `yield_many/2` returns results in the same order as
  # the input task list, so we zip mount names back in positionally.
  defp scan_mounts(workspace, mounts, terms, timeout) do
    named_tasks =
      Enum.map(mounts, fn mount ->
        {mount.name, Task.async(fn -> scan_mount(workspace, mount, terms) end)}
      end)

    tasks = Enum.map(named_tasks, fn {_name, task} -> task end)
    names = Enum.map(named_tasks, fn {name, _task} -> name end)

    names
    |> Enum.zip(Task.yield_many(tasks, timeout))
    |> Enum.reduce({[], []}, fn {name, {task, outcome}}, {hits, skipped} ->
      case outcome || Task.shutdown(task, :brutal_kill) do
        {:ok, mount_hits} -> {hits ++ mount_hits, skipped}
        _ -> {hits, skipped ++ [name]}
      end
    end)
  end

  defp scan_mount(_workspace, mount, terms) do
    root = mount.root

    root
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.flat_map(fn abs ->
      case File.read(abs) do
        {:ok, content} -> score_file(root, abs, mount.name, content, terms)
        _ -> []
      end
    end)
  end

  defp score_file(root, abs, mount_name, content, terms) do
    {_fm, body} = Valea.ICM.split_frontmatter(content)
    title = title_of(body, abs)
    headings = headings_of(body)

    title_down = String.downcase(title)
    headings_down = String.downcase(headings)
    body_down = String.downcase(body)

    if Enum.all?(terms, fn t ->
         String.contains?(title_down, t) or String.contains?(headings_down, t) or
           String.contains?(body_down, t)
       end) do
      score =
        Enum.reduce(terms, 0, fn t, acc ->
          acc +
            if(String.contains?(title_down, t), do: 5, else: 0) +
            if(String.contains?(headings_down, t), do: 3, else: 0) +
            occurrences(body_down, t)
        end)

      rel = Path.relative_to(abs, root)

      [
        %{
          path: rel,
          mount: mount_name,
          title: title,
          snippet: snippet(body, body_down, terms),
          terms: terms,
          score: score
        }
      ]
    else
      []
    end
  end

  defp occurrences(haystack, needle) do
    haystack |> :binary.matches(needle) |> length() |> min(10)
  end

  defp title_of(body, abs) do
    body
    |> String.split("\n")
    |> Enum.take(20)
    |> Enum.find_value(fn line ->
      case line do
        "# " <> rest -> String.trim(rest)
        _ -> nil
      end
    end)
    |> case do
      nil -> Path.basename(abs, ".md")
      t -> t
    end
  end

  defp headings_of(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "#"))
    |> Enum.join("\n")
  end

  # Cut a window around the first body match; expand to whitespace
  # boundaries so we never split a grapheme or a word.
  defp snippet(body, body_down, terms) do
    pos =
      terms
      |> Enum.flat_map(fn t ->
        case :binary.match(body_down, t) do
          {p, _} -> [p]
          :nomatch -> []
        end
      end)
      |> Enum.min(fn -> 0 end)

    # `pos` is a byte offset into `body_down`; `String.downcase/1` can, for a
    # handful of Unicode characters, change a string's byte length (e.g. the
    # Turkish dotted "İ"), so `body_down` and `body` are not guaranteed to be
    # byte-identical in length. Clamping `pos` into `body`'s own byte range
    # before the window math keeps this a no-op for the overwhelming common
    # case (equal lengths) while preventing a negative-length `binary_part/3`
    # call on the rare mismatched one.
    safe_pos = pos |> max(0) |> min(byte_size(body))
    from = max(safe_pos - @snippet_radius, 0)
    len = max(min(@snippet_radius * 2, byte_size(body) - from), 0)

    body
    |> binary_part(from, len)
    |> trim_to_valid_utf8()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # binary_part can cut mid-codepoint at either end — drop bytes until
  # both edges are valid UTF-8.
  defp trim_to_valid_utf8(bin) do
    bin |> trim_leading_invalid() |> trim_trailing_invalid()
  end

  defp trim_leading_invalid(<<_, rest::binary>> = bin) do
    if String.valid?(bin), do: bin, else: trim_leading_invalid(rest)
  end

  defp trim_leading_invalid(<<>>), do: <<>>

  defp trim_trailing_invalid(bin) do
    if String.valid?(bin) or byte_size(bin) == 0 do
      bin
    else
      trim_trailing_invalid(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end
end
