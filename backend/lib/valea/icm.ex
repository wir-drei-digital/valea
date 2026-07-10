defmodule Valea.ICM do
  @moduledoc """
  Read access to the workspace's icm/ tree — the user's business memory.
  The filesystem is the source of truth. This module is the single
  containment chokepoint for icm reads: every path is expanded and checked
  against the icm root AFTER expansion, so `..` (or a `~`) can never escape.
  """

  alias Valea.Markdown.ProseMirror
  alias Valea.Workspace.Manager

  def uri(rel_path), do: "icm://" <> rel_path

  def tree do
    with {:ok, root} <- icm_root() do
      {:ok, build_tree(root, root)}
    end
  end

  def page(rel_path) do
    with {:ok, root} <- icm_root(),
         {:ok, abs} <- contain(root, rel_path) do
      case File.read(abs) do
        {:ok, content} ->
          case ProseMirror.from_markdown(content) do
            {:ok, pm} ->
              {:ok,
               %{
                 path: rel_path,
                 title: title_of(content, abs),
                 uri: uri(rel_path),
                 content: content,
                 hash: sha256_hex(content),
                 prosemirror: pm
               }}

            {:error, reason} ->
              {:error, {:conversion_failed, reason}}
          end

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Writes `pm_map` (ProseMirror JSON) back to `rel_path` as markdown, guarded
  by an optimistic-concurrency check against `base_hash`.

  Returns `{:ok, %{hash: new_hash, saved_at: iso8601}}` on success, or
  `{:error, :page_changed}` if the file's current content hash doesn't match
  `base_hash` (someone else — or another process — changed it since it was
  read), `{:error, :not_found}` if the file doesn't exist,
  `{:error, :outside_workspace}` / `{:error, :no_workspace}` from the
  containment chokepoint, or another error tuple on write failure.

  The write is atomic: markdown is written to a `.tmp` sibling file and then
  renamed over the target, so readers never observe a partial write.
  """
  def save_page(rel_path, pm_map, base_hash) do
    with {:ok, root} <- icm_root(),
         {:ok, abs} <- contain(root, rel_path),
         {:ok, current} <- read_for_save(abs) do
      if sha256_hex(current) == base_hash do
        write_page(abs, pm_map)
      else
        {:error, :page_changed}
      end
    end
  end

  defp read_for_save(abs) do
    case File.read(abs) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_page(abs, pm_map) do
    with {:ok, markdown} <- ProseMirror.to_markdown(pm_map) do
      tmp = abs <> ".tmp"

      with :ok <- File.write(tmp, markdown),
           :ok <- File.rename(tmp, abs) do
        {:ok, %{hash: sha256_hex(markdown), saved_at: DateTime.to_iso8601(DateTime.utc_now())}}
      end
    end
  end

  defp sha256_hex(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp icm_root do
    case Manager.current() do
      {:ok, %{path: ws}} -> {:ok, Path.join(ws, "icm")}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  defp contain(root, rel_path) do
    abs = Path.expand(rel_path, root)

    if String.starts_with?(abs, root <> "/") do
      {:ok, abs}
    else
      {:error, :outside_workspace}
    end
  end

  defp build_tree(dir, root) do
    dir
    |> File.ls!()
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.map(&node_for(Path.join(dir, &1), root))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn n -> {if(n.type == :folder, do: 0, else: 1), String.downcase(n.name)} end)
  end

  defp node_for(abs, root) do
    rel = Path.relative_to(abs, root)

    cond do
      File.dir?(abs) ->
        children = build_tree(abs, root)

        %{
          name: Path.basename(abs),
          path: rel,
          type: :folder,
          children: children,
          page_count: count_pages(children)
        }

      Path.extname(abs) == ".md" ->
        %{
          name: Path.basename(abs, ".md"),
          path: rel,
          type: :page,
          uri: uri(rel)
        }

      true ->
        nil
    end
  end

  defp count_pages(children) do
    Enum.reduce(children, 0, fn
      %{type: :page}, acc -> acc + 1
      %{type: :folder, page_count: n}, acc -> acc + n
    end)
  end

  defp title_of(content, abs) do
    content
    |> String.split("\n", parts: 20)
    |> Enum.find_value(fn
      "# " <> title -> String.trim(title)
      _ -> nil
    end) || Path.basename(abs, ".md")
  end
end
