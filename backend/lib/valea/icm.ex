defmodule Valea.ICM do
  @moduledoc """
  Read access to the workspace's icm/ tree — the user's business memory.
  The filesystem is the source of truth. This module is the single
  containment chokepoint for icm reads: every path is expanded and checked
  against the icm root AFTER expansion, so `..` (or a `~`) can never escape.
  """

  alias Valea.ICM.References
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

  defp atomic_write(abs, bytes) do
    tmp = abs <> ".tmp"

    with :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, abs) do
      :ok
    end
  end

  defp write_page(abs, pm_map) do
    with {:ok, markdown} <- ProseMirror.to_markdown(pm_map),
         :ok <- atomic_write(abs, markdown) do
      {:ok, %{hash: sha256_hex(markdown), saved_at: DateTime.to_iso8601(DateTime.utc_now())}}
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

  @doc """
  Validates a name for pages and folders.

  Rules:
  - Must be non-empty after trimming
  - Must not contain `/` or `\`
  - Must not start with `.`
  - Must be NFC-normalized
  """
  def valid_name?(name) do
    case normalize_name(name) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp normalize_name(name) do
    normalized = String.normalize(name, :nfc)
    trimmed = String.trim(normalized)

    cond do
      byte_size(trimmed) == 0 -> {:error, :name_invalid}
      String.contains?(trimmed, ["/", "\\"]) -> {:error, :name_invalid}
      String.starts_with?(trimmed, ".") -> {:error, :name_invalid}
      true -> {:ok, trimmed}
    end
  end

  defp check_parent_contained(_root, ""), do: :ok

  defp check_parent_contained(root, parent_rel_path) do
    case contain(root, parent_rel_path) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_parent_is_directory(parent_abs) do
    cond do
      not File.exists?(parent_abs) ->
        :ok

      File.dir?(parent_abs) ->
        :ok

      true ->
        {:error, :name_invalid}
    end
  end

  defp ensure_parent_directory(parent_abs) do
    case File.mkdir_p(parent_abs) do
      :ok -> :ok
      {:error, :enotdir} -> {:error, :name_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a new page in the given parent folder.

  Returns `{:ok, %{path: rel_path}} | {:error, reason}` where rel_path is the
  relative path from the icm root.

  The page is seeded with a markdown title header using the name (without .md extension).

  Errors:
  - `:name_invalid` - name fails validation
  - `:already_exists` - a file or folder already exists at that path
  - `:outside_workspace` - path would escape the icm root
  - `:no_workspace` - no workspace is currently active
  """
  def create_page(parent_rel_path, name) do
    with {:ok, normalized_name} <- normalize_name(name),
         {:ok, root} <- icm_root(),
         :ok <- check_parent_contained(root, parent_rel_path),
         parent_abs <- Path.join(root, parent_rel_path),
         :ok <- check_parent_is_directory(parent_abs),
         name_with_ext <- ensure_md_extension(normalized_name),
         abs <- Path.join(parent_abs, name_with_ext),
         {:ok, _} <- contain(root, Path.relative_to(abs, root)),
         false <- File.exists?(abs),
         :ok <- ensure_parent_directory(parent_abs) do
      title = Path.basename(name_with_ext, ".md")
      # No trailing newline: matches the canonical serializer form
      # (`ProseMirror.to_markdown/1` never emits a trailing newline), so a
      # freshly created page round-trips byte-identically through
      # from_markdown/to_markdown instead of gaining a phantom diff on first
      # save.
      content = "# " <> title

      write_string_to_file(abs, content) |> format_create_response(abs, root)
    else
      {:error, :name_invalid} -> {:error, :name_invalid}
      {:error, reason} -> {:error, reason}
      true -> {:error, :already_exists}
    end
  end

  @doc """
  Creates a new folder in the given parent folder.

  Returns `{:ok, %{path: rel_path}} | {:error, reason}` where rel_path is the
  relative path from the icm root.

  Errors:
  - `:name_invalid` - name fails validation
  - `:already_exists` - a file or folder already exists at that path
  - `:outside_workspace` - path would escape the icm root
  - `:no_workspace` - no workspace is currently active
  """
  def create_folder(parent_rel_path, name) do
    with {:ok, normalized_name} <- normalize_name(name),
         {:ok, root} <- icm_root(),
         :ok <- check_parent_contained(root, parent_rel_path),
         parent_abs <- Path.join(root, parent_rel_path),
         :ok <- check_parent_is_directory(parent_abs),
         abs <- Path.join(parent_abs, normalized_name),
         {:ok, _} <- contain(root, Path.relative_to(abs, root)),
         false <- File.exists?(abs),
         :ok <- ensure_parent_directory(parent_abs),
         :ok <- create_directory(abs) do
      rel = Path.relative_to(abs, root)
      {:ok, %{path: rel}}
    else
      {:error, :name_invalid} -> {:error, :name_invalid}
      {:error, reason} -> {:error, reason}
      true -> {:error, :already_exists}
    end
  end

  defp create_directory(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :enotdir} -> {:error, :name_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_md_extension(name) do
    cond do
      String.ends_with?(name, ".md") ->
        name

      String.ends_with?(name, ".") ->
        String.slice(name, 0..-2//1) <> ".md"

      true ->
        name <> ".md"
    end
  end

  defp format_create_response({:ok, _}, abs, root) do
    rel = Path.relative_to(abs, root)
    {:ok, %{path: rel}}
  end

  defp format_create_response({:error, reason}, _abs, _root) do
    {:error, reason}
  end

  defp write_string_to_file(abs, content) do
    case atomic_write(abs, content) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Renames a page or folder in place (same parent, new basename), rewriting
  any workflow references to it (or, for a folder, to anything it contains)
  along the way.

  Returns `{:ok, %{path: new_rel_path, updated_workflows: [names]}}` where
  `names` are the display names of the workflows whose references were
  rewritten (deduplicated, sorted).

  If a workflow rewrite fails, returns `{:error, {:rewrite_failed, filename, reason}}`.
  Note: The file rename itself has already happened at this point; the filesystem
  is not rolled back. The error is returned to allow the user to decide how to
  proceed (e.g., via version control recovery or manual intervention).

  Errors:
  - `:name_invalid` - the new name fails validation
  - `:already_exists` - a file or folder already exists at the new path
  - `:not_found` - nothing exists at `rel_path`
  - `:outside_workspace` - a path would escape the icm root
  - `:no_workspace` - no workspace is currently active
  - `{:rewrite_failed, filename, reason}` - a workflow reference rewrite failed
  """
  def rename(rel_path, new_name) do
    with {:ok, root} <- icm_root(),
         {:ok, old_abs} <- contain(root, rel_path),
         true <- File.exists?(old_abs),
         {:ok, normalized_name} <- normalize_name(new_name),
         is_dir <- File.dir?(old_abs),
         name_with_ext <- rename_target_name(is_dir, normalized_name),
         new_rel <- join_rel(parent_of(rel_path), name_with_ext),
         {:ok, new_abs} <- contain(root, new_rel),
         false <- File.exists?(new_abs) do
      do_rename(root, rel_path, new_rel, old_abs, new_abs, is_dir)
    else
      false -> {:error, :not_found}
      true -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rename_target_name(true, normalized_name), do: normalized_name
  defp rename_target_name(false, normalized_name), do: ensure_md_extension(normalized_name)

  defp parent_of(rel_path) do
    case Path.dirname(rel_path) do
      "." -> ""
      other -> other
    end
  end

  defp join_rel("", name), do: name
  defp join_rel(parent, name), do: Path.join(parent, name)

  defp do_rename(root, old_rel, new_rel, old_abs, new_abs, true) do
    # Collect every .md file under the folder — with its old and new
    # relative path — BEFORE moving anything on disk. Reference rewrites
    # then run per-file on the exact `icm/<child path>` string, so a
    # sibling folder whose name happens to start with the same prefix
    # (e.g. renaming "Offers" while "Offers Extra" also exists) is never
    # touched: its files were never in this collected list.
    child_pairs = collect_md_children(old_abs, root, old_rel, new_rel)
    File.rename!(old_abs, new_abs)

    # Workflows can also reference an entire folder via a wildcard glob
    # (`icm/<folder>/*` — see `priv/workspace_template/workflows/*.yaml`),
    # which `collect_md_children` never surfaces (it only walks concrete
    # `.md` files that existed on disk at rename time). Rewrite that exact
    # `icm/<old_rel>/*` needle too, via the same precision-safe full-string
    # mechanism as every other reference — the trailing `/*` keeps this from
    # ever matching a sibling folder's wildcard (e.g. "Offers" vs.
    # "Offers Extra").
    wildcard_pair = {old_rel <> "/*", new_rel <> "/*"}

    case rewrite_children(child_pairs ++ [wildcard_pair]) do
      {:ok, updated_workflows} ->
        {:ok, %{path: new_rel, updated_workflows: updated_workflows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_rename(_root, old_rel, new_rel, old_abs, new_abs, false) do
    File.rename!(old_abs, new_abs)

    case rewrite_children([{old_rel, new_rel}]) do
      {:ok, updated_workflows} ->
        {:ok, %{path: new_rel, updated_workflows: updated_workflows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_md_children(old_abs, root, old_rel, new_rel) do
    old_abs
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
    |> Enum.map(fn child_old_rel ->
      suffix = String.trim_leading(child_old_rel, old_rel)
      {child_old_rel, new_rel <> suffix}
    end)
  end

  defp rewrite_children(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {old_rel, new_rel}, {:ok, names} ->
      {:ok, refs} = References.referencing_workflows(old_rel)

      case References.rewrite(old_rel, new_rel) do
        {:ok, _updated_files} ->
          new_names = Enum.map(refs, & &1.name)
          {:cont, {:ok, names ++ new_names}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, names} -> {:ok, names |> Enum.uniq() |> Enum.sort()}
      error -> error
    end)
  end

  @doc """
  Deletes a page or folder (recursively). Never touches workflow
  references — deleting is a destructive action the user drives directly;
  stale workflow references are left for the user (or a future validation
  pass) to notice, rather than silently rewritten out from under them.

  Returns `{:ok, %{deleted: true}}`.

  Errors:
  - `:not_found` - nothing exists at `rel_path`
  - `:outside_workspace` - path would escape the icm root
  - `:no_workspace` - no workspace is currently active
  """
  def delete(rel_path) do
    with {:ok, root} <- icm_root(),
         {:ok, abs} <- contain(root, rel_path) do
      cond do
        File.dir?(abs) ->
          File.rm_rf!(abs)
          {:ok, %{deleted: true}}

        File.regular?(abs) ->
          File.rm!(abs)
          {:ok, %{deleted: true}}

        true ->
          {:error, :not_found}
      end
    end
  end
end
