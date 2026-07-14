defmodule Valea.ICM.Backlinks do
  @moduledoc """
  Inbound page links for a target: cheap filename substring pre-filter
  across every `.md` file IN SCOPE, then AST confirmation — only real
  Link/Image destinations that resolve to the target count (the References
  trick, generalized; prose mentions and code fences never match, because
  they are not Link nodes).

  Addressed by `mount_key` + a path relative to that ICM's own root (task
  4.2's re-key). SCOPE (Task 5.6, spec decision (b)): the target's own
  `mount_key` ICM, plus every ICM it directly declares related via its own
  `CONTEXT.md` (`Valea.Mounts.scoped_roots/2`) — the same session-context
  boundary the redesign enforces everywhere else. A link living in a
  DIFFERENT, un-declared ICM that points at this target is still not
  discovered (by design, not a gap: that ICM is outside the session
  context boundary). Each returned link's `mount` field names the SPECIFIC
  ICM the source page actually lives in — the primary when the link is
  local, a related ICM's own key when it isn't — never blindly the queried
  `mount_key`, so `(mount, source_path)` always addresses the real file.
  """

  alias Valea.Mounts
  alias Valea.Workspace.Manager

  @mdex_extensions [table: true, tasklist: true, strikethrough: true]

  @doc """
  Inbound Link/Image references to `target_rel_path` (relative to
  `mount_key`'s own root) within every `.md` file IN SCOPE (see moduledoc
  "SCOPE").

  Every candidate `.md` file under a scoped mount whose raw content
  contains the target's basename is parsed and walked; only a real
  `MDEx.Link`/`MDEx.Image` node whose destination RESOLVES (relative to the
  linking page's own directory, or absolute) to the target counts — a
  bare prose mention of the filename, or the same text inside a code span,
  is never a Link/Image node and so never matches. `http(s)://`, `mailto:`,
  and `#anchor` destinations are ignored outright (never local content).

  Returns `{:ok, [%{source_path:, mount:, link_text:}]}`, sorted by
  `source_path` (relative to the SOURCE's own mount root — see moduledoc),
  with at most one entry per source page (the first matching link/image
  text on that page wins if it links to the target more than once).
  `{:error, :outside_workspace}` when `mount_key` doesn't name a currently
  enabled, non-degraded mount; `{:error, :no_workspace}` when no workspace
  is open.
  """
  @spec backlinks(String.t(), String.t()) ::
          {:ok, [map()]} | {:error, :outside_workspace | :no_workspace}
  def backlinks(mount_key, target_rel_path) do
    with {:ok, mount} <- resolve_mount(mount_key),
         {:ok, workspace} <- workspace_root() do
      target_abs = to_abs(mount.root, target_rel_path)
      needle = Path.basename(target_rel_path)
      # Percent-encoded destinations (e.g. `%20` for a space) appear in raw
      # file bytes as the encoded form, not the decoded basename — match
      # either. This only catches a straight `URI.encode/1` of the basename;
      # exotic/partial/mixed encodings of the same name are not caught (rare
      # in practice — the common case is spaces encoded as `%20`).
      encoded_needle = URI.encode(needle)

      links =
        for scoped <- Mounts.scoped_roots(workspace, mount_key),
            abs <- Path.wildcard(Path.join(scoped.root, "**/*.md")),
            {:ok, content} <- [File.read(abs)],
            String.contains?(content, needle) or String.contains?(content, encoded_needle),
            source_rel = Path.relative_to(abs, scoped.root),
            not (scoped.root == mount.root and source_rel == target_rel_path),
            text <- confirmed_link_texts(scoped.root, source_rel, content, target_abs) do
          %{source_path: source_rel, mount: scoped.name, link_text: text}
        end

      {:ok, Enum.sort_by(links, & &1.source_path)}
    end
  end

  @doc "All Link/Image destinations of `content` (parsed as if it lived at `source_rel`, relative to `mount_root`), resolved to absolute paths, with their text."
  @spec destinations(String.t(), String.t(), String.t()) :: [
          %{url: String.t(), abs: String.t(), text: String.t()}
        ]
  def destinations(mount_root, source_rel, content) do
    case parse(content) do
      {:ok, doc} ->
        source_dir = Path.dirname(to_abs(mount_root, source_rel))

        doc
        |> walk([])
        # `walk/2` prepends as it recurses (reverse-preorder); reverse here —
        # same compensation `plain_text/1` applies — so destinations come
        # back in DOCUMENT order and `confirmed_link_texts`'s `hd/1` picks
        # the FIRST matching link/image text, per this module's moduledoc.
        |> Enum.reverse()
        |> Enum.flat_map(fn
          %MDEx.Link{url: url} = n -> dest_entry(url, source_dir, plain_text(n))
          %MDEx.Image{url: url} = n -> dest_entry(url, source_dir, plain_text(n))
          _ -> []
        end)

      :error ->
        []
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

  # `MDEx.parse_document/2` returns `{:ok, doc}` on ordinary content but
  # RAISES `ArgumentError` — rather than returning `{:error, _}` — when the
  # input isn't valid UTF-8 (confirmed against the installed 0.13.3; mix.exs
  # pins `~> 0.7` but the resolved dependency is newer). Enabled mounts can
  # include external, by-reference directories this app didn't create, so a
  # single binary-garbage `.md` file on disk must not crash the whole scan —
  # caught here and folded into the same "no destinations" outcome as any
  # other parse failure.
  defp parse(content) do
    case MDEx.parse_document(content, extension: @mdex_extensions) do
      {:ok, doc} -> {:ok, doc}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp confirmed_link_texts(mount_root, source_rel, content, target_abs) do
    mount_root
    |> destinations(source_rel, content)
    |> Enum.filter(&(&1.abs == target_abs))
    |> Enum.map(& &1.text)
    |> case do
      [] -> []
      texts -> [hd(texts)]
    end
  end

  defp dest_entry(url, source_dir, text) do
    cond do
      not is_binary(url) or url == "" ->
        []

      String.starts_with?(url, ["http://", "https://", "mailto:", "#"]) ->
        []

      String.starts_with?(url, "/") ->
        [%{url: url, abs: Path.expand(URI.decode(url)), text: text}]

      true ->
        [%{url: url, abs: Path.expand(URI.decode(url), source_dir), text: text}]
    end
  end

  # Version-proof manual AST walk: every MDEx node struct that HAS children
  # carries them under `:nodes` (Document, Paragraph, Heading, Link, Image,
  # List, ListItem, Table, TableRow, Strong, Emph, Strikethrough, TaskItem,
  # …) — the map pattern below matches on that SHAPE, not on a specific
  # struct name, so a leaf node (Text, Code, ThematicBreak, HtmlBlock, …),
  # which simply has no `:nodes` key, falls straight through to the
  # catch-all clause. A node type MDEx adds later that carries children the
  # same way is walked correctly without this module needing to know its
  # name.
  defp walk(%{nodes: children} = node, acc) when is_list(children) do
    Enum.reduce(children, [node | acc], &walk/2)
  end

  defp walk(node, acc), do: [node | acc]

  defp plain_text(node) do
    node
    |> walk([])
    |> Enum.flat_map(fn
      %MDEx.Text{literal: s} -> [s]
      %MDEx.Code{literal: s} -> [s]
      _ -> []
    end)
    |> Enum.reverse()
    |> Enum.join()
    |> String.trim()
  end

  defp to_abs(_mount_root, "/" <> _ = abs), do: Path.expand(abs)
  defp to_abs(mount_root, rel), do: Path.expand(rel, mount_root)
end
