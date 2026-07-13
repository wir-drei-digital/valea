defmodule Valea.ICM.Backlinks do
  @moduledoc """
  Inbound page links for a target: cheap filename substring pre-filter
  across enabled mounts, then AST confirmation — only real Link/Image
  destinations that resolve to the target count (the References trick,
  generalized; prose mentions and code fences never match, because they
  are not Link nodes).
  """

  alias Valea.Mounts

  @mdex_extensions [table: true, tasklist: true, strikethrough: true]

  @doc """
  Inbound Link/Image references to `target_path` across every enabled,
  non-degraded mount. `target_path` is in tree vocabulary (workspace-relative
  `mounts/<name>/…` for an embedded page, absolute for an external one) —
  same shape `Valea.ICM.References.referencing_workflows/1` takes.

  Every candidate `.md` file under an enabled mount whose raw content
  contains the target's basename is parsed and walked; only a real
  `MDEx.Link`/`MDEx.Image` node whose destination RESOLVES (relative to the
  linking page's own directory, or absolute) to `target_path` counts — a
  bare prose mention of the filename, or the same text inside a code span,
  is never a Link/Image node and so never matches. `http(s)://`, `mailto:`,
  and `#anchor` destinations are ignored outright (never local content).

  Returns `{:ok, [%{source_path:, mount:, link_text:}]}`, sorted by
  `source_path`, with at most one entry per source page (the first matching
  link/image text on that page wins if it links to the target more than
  once).
  """
  @spec backlinks(String.t(), String.t()) :: {:ok, [map()]}
  def backlinks(workspace, target_path) do
    target_abs = to_abs(workspace, target_path)
    needle = Path.basename(target_path)

    links =
      for mount <- Mounts.enabled(workspace),
          root = mount_root(workspace, mount),
          prefix = mount.rel_root || mount.root,
          abs <- Path.wildcard(Path.join(root, "**/*.md")),
          {:ok, content} <- [File.read(abs)],
          String.contains?(content, needle),
          source_rel = Path.join(prefix, Path.relative_to(abs, root)),
          source_rel != target_path,
          text <- confirmed_link_texts(workspace, source_rel, content, target_abs) do
        %{source_path: source_rel, mount: mount.name, link_text: text}
      end

    {:ok, Enum.sort_by(links, & &1.source_path)}
  end

  @doc "All Link/Image destinations of `content` (parsed as if it lived at `source_rel`), resolved to absolute paths, with their text."
  @spec destinations(String.t(), String.t(), String.t()) :: [
          %{url: String.t(), abs: String.t(), text: String.t()}
        ]
  def destinations(workspace, source_rel, content) do
    case parse(content) do
      {:ok, doc} ->
        source_dir = Path.dirname(to_abs(workspace, source_rel))

        doc
        |> walk([])
        |> Enum.flat_map(fn
          %MDEx.Link{url: url} = n -> dest_entry(url, source_dir, plain_text(n))
          %MDEx.Image{url: url} = n -> dest_entry(url, source_dir, plain_text(n))
          _ -> []
        end)

      :error ->
        []
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

  defp confirmed_link_texts(workspace, source_rel, content, target_abs) do
    workspace
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
      not is_binary(url) or url == "" -> []
      String.starts_with?(url, ["http://", "https://", "mailto:", "#"]) -> []
      String.starts_with?(url, "/") -> [%{url: url, abs: Path.expand(url), text: text}]
      true -> [%{url: url, abs: Path.expand(url, source_dir), text: text}]
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

  defp mount_root(workspace, %{rel_root: rel}) when is_binary(rel), do: Path.join(workspace, rel)
  defp mount_root(_workspace, %{root: root}), do: root

  defp to_abs(_workspace, "/" <> _ = abs), do: Path.expand(abs)
  defp to_abs(workspace, rel), do: Path.expand(rel, workspace)
end
