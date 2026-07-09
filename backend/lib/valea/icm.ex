defmodule Valea.ICM do
  @moduledoc """
  Read access to the workspace's icm/ tree — the user's business memory.
  The filesystem is the source of truth. This module is the single
  containment chokepoint for icm reads: every path is expanded and checked
  against the icm root AFTER expansion, so `..` (or a `~`) can never escape.
  """

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
          {:ok,
           %{
             path: rel_path,
             title: title_of(content, abs),
             uri: uri(rel_path),
             content: content
           }}

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
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
