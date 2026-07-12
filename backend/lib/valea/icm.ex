defmodule Valea.ICM do
  @moduledoc """
  Read/write access to the workspace's mounted ICM trees — the user's
  business memory, now split across `mounts/<name>/` modules (Plan A)
  instead of a single hardcoded `icm/` root. The filesystem is the source
  of truth.

  This module is still the single containment chokepoint for every ICM
  path, just parameterized per mount: `Valea.Mounts.mount_for/1` only
  ATTRIBUTES a workspace-relative path (`mounts/<name>/…`) to the mount
  that owns it — per its own docs, that's attribution, not authorization.
  Every function here re-expands the path against THAT mount's own root
  (via the unchanged `contain/2`) after attribution, so `..` (or a `~`) can
  never escape — including a `..` that tries to cross from one mount into
  another (attribution still names the first mount; containment then
  rejects the escaped path because it falls outside that mount's root).

  Every public function takes/returns a full workspace-relative path
  (`mounts/<name>/…`). Internally, the `mounts/<name>` prefix is stripped
  before delegating to the mount-relative containment/tree-building logic
  (unchanged from the single-root era) and reattached on the way back out.

  DECISION: `page/1` — and `save_page/3`, `create_page/2`, `create_folder/2`,
  `rename/2`, `delete/1` — resolve their target mount via `Mounts.mount_for/1`
  REGARDLESS of that mount's enabled state. A disabled mount's page still
  opens, edits, and saves fine here. Enabled-gating (what an agent or
  `read_roots` may act on) is that consumer's concern, not the editor's
  containment chokepoint — excluding disabled mounts here would make it
  impossible for the UI to ever inspect or fix a disabled mount's content.

  `tree/0` is the one function scoped to `Mounts.enabled/0`: it returns one
  entry per ENABLED, non-degraded EMBEDDED mount (external `rel_root: nil`
  mounts are not surfaced until A2-T5b), grouped:

      {:ok, [%{mount: name, title: manifest_name, root_rel: "mounts/<name>",
               tree: [<node>, ...]}, ...]}

  where `<node>` is the same folder/page node shape `tree/0` always
  produced, just with `path` (and a page's `uri`) now workspace-relative.
  """

  alias Valea.ICM.References
  alias Valea.Markdown.ProseMirror
  alias Valea.Mounts

  def uri(rel_path), do: "icm://" <> rel_path

  def tree do
    with {:ok, mounts} <- Mounts.enabled() do
      {:ok,
       mounts
       # EXTERNAL (by-reference) mounts have `rel_root: nil` — no
       # workspace-relative form for the `mounts/<name>/…` node paths this
       # tree is built from. They are deliberately not surfaced here yet;
       # A2-T5b adds external groups to the tree.
       |> Enum.reject(&is_nil(&1.rel_root))
       |> Enum.map(fn m ->
         %{
           mount: m.name,
           title: m.manifest.name,
           root_rel: m.rel_root,
           tree: prefix_tree(build_tree(m.root, m.root), m.rel_root)
         }
       end)}
    end
  end

  def page(rel_path) do
    with {:ok, mount} <- mount_root_for(rel_path),
         {:ok, abs} <- contain(mount.root, mount_relative(rel_path)) do
      case File.read(abs) do
        {:ok, content} ->
          {block, body} = split_frontmatter(content)

          case ProseMirror.from_markdown(body) do
            {:ok, pm} ->
              {:ok,
               %{
                 path: rel_path,
                 title: title_of(content, abs),
                 uri: uri(rel_path),
                 content: content,
                 hash: sha256_hex(content),
                 prosemirror: pm,
                 frontmatter: parse_frontmatter(block)
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
  Splits an optional leading YAML frontmatter block off `input`. Returns
  `{frontmatter_block, body}` where `frontmatter_block` is `""` when no
  frontmatter is present (or it's unterminated — treated as ordinary body
  text), or the exact bytes `"---\\n...\\n---\\n"` (delimiters and the
  closing newline included) when present. `body` is everything after the
  block, byte-for-byte — including whatever leading blank line separates it
  from the closing delimiter in the source file.

  `frontmatter_block <> body == input` always holds.
  """
  @spec split_frontmatter(binary()) :: {binary(), binary()}
  def split_frontmatter("---\n" <> rest = input) do
    case String.split(rest, "\n---\n", parts: 2) do
      [yaml, body] -> {"---\n" <> yaml <> "\n---\n", body}
      _ -> {"", input}
    end
  end

  def split_frontmatter(input), do: {"", input}

  defp parse_frontmatter(""), do: nil

  defp parse_frontmatter(block) do
    yaml = block |> String.trim_leading("---\n") |> String.trim_trailing("---\n")

    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
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
    with {:ok, mount} <- mount_root_for(rel_path),
         {:ok, abs} <- contain(mount.root, mount_relative(rel_path)),
         {:ok, current} <- read_for_save(abs) do
      if sha256_hex(current) == base_hash do
        {block, _old_body} = split_frontmatter(current)
        write_page(abs, block, pm_map)
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

  defp write_page(abs, frontmatter_block, pm_map) do
    with {:ok, body} <- ProseMirror.to_markdown(pm_map) do
      bytes = frontmatter_block <> body

      case atomic_write(abs, bytes) do
        :ok ->
          {:ok, %{hash: sha256_hex(bytes), saved_at: DateTime.to_iso8601(DateTime.utc_now())}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp sha256_hex(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  # Resolves the mount owning `rel_path` (a full `mounts/<name>/…`
  # workspace-relative path) via `Mounts.mount_for/1` — attribution only, see
  # moduledoc. `:not_in_mount` (no `mounts/<name>` prefix at all, or a name
  # that isn't actually a discovered mount) is folded into `:outside_workspace`
  # — from this module's point of view, a path that doesn't name a real mount
  # is just as inaccessible as one that escapes a real mount's root.
  defp mount_root_for(rel_path) do
    case Mounts.mount_for(rel_path) do
      {:ok, mount} -> {:ok, mount}
      {:error, :not_in_mount} -> {:error, :outside_workspace}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  # Strips the leading `mounts/<name>` segment off a workspace-relative path,
  # leaving the path relative to THAT mount's own root — the same shape every
  # `contain/2`/`build_tree/2` call took before mounts existed. Only ever
  # called after `mount_root_for/1` already confirmed `rel_path` has this
  # shape; the fallback is defensive, not a normal code path.
  defp mount_relative(rel_path) do
    case Path.split(rel_path) do
      ["mounts", _name | rest] -> Enum.join(rest, "/")
      _ -> rel_path
    end
  end

  defp to_workspace_rel(mount, mount_rel_path), do: Path.join(mount.rel_root, mount_rel_path)

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
    # The mount's own manifest (`<root>/icm.yaml` — see `Valea.Mounts.Manifest`)
    # is mount infrastructure, not knowledge content: exclude it at the ROOT
    # level only, same spirit as the dotfile filter above. A nested folder's
    # own `icm.yaml` (just a file that happens to share the name) still lists.
    |> Enum.reject(&(dir == root and &1 == "icm.yaml"))
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

      File.regular?(abs) ->
        # A-T15 fix wave: non-.md regular files (media, PDFs, ...) surface as
        # :file leaves so the Knowledge UI can list them (with `ext` for icon
        # selection — normalized lowercase so ".PDF"/".pdf" map the same).
        # Hidden files are already excluded upstream (`build_tree/2` rejects
        # dot-prefixed names before this is ever called). Deliberately no
        # `uri`: only .md pages are icm:// addressable/editable; rename
        # cascades ignore these too (`collect_md_children`/`References` glob
        # `*.md` only).
        %{
          name: Path.basename(abs),
          path: rel,
          type: :file,
          ext: abs |> Path.extname() |> String.downcase()
        }

      true ->
        # Anything that is neither a directory, a .md page, nor a regular
        # file (sockets, fifos, dangling symlinks) stays out of the tree.
        nil
    end
  end

  # Rewrites `build_tree/2`'s mount-relative node `path`s (and a page node's
  # `uri`, which is derived from `path`) into workspace-relative
  # (`mounts/<name>/…`) form — the one prefixing pass `tree/0` needs, since
  # `build_tree/2` itself stays mount-root-relative (unchanged, shared with
  # every other per-mount operation in this module).
  defp prefix_tree(nodes, prefix) do
    Enum.map(nodes, fn
      %{type: :folder, children: children} = node ->
        %{node | path: Path.join(prefix, node.path), children: prefix_tree(children, prefix)}

      %{type: :page} = node ->
        new_path = Path.join(prefix, node.path)
        %{node | path: new_path, uri: uri(new_path)}

      # A :file leaf has no uri to rewrite — only its path gains the prefix.
      %{type: :file} = node ->
        %{node | path: Path.join(prefix, node.path)}
    end)
  end

  defp count_pages(children) do
    Enum.reduce(children, 0, fn
      %{type: :page}, acc -> acc + 1
      %{type: :folder, page_count: n}, acc -> acc + n
      # :file leaves are listed but never counted as pages.
      %{type: :file}, acc -> acc
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

  `parent_rel_path` is a full workspace-relative path (`mounts/<name>` for
  the mount's own root, or `mounts/<name>/<subfolder>` beneath it).

  Returns `{:ok, %{path: rel_path}} | {:error, reason}` where `rel_path` is
  workspace-relative (`mounts/<name>/…`).

  The page is seeded with a markdown title header using the name (without .md extension).

  Errors:
  - `:name_invalid` - name fails validation
  - `:already_exists` - a file or folder already exists at that path
  - `:outside_workspace` - path would escape the owning mount's root, or
    doesn't name a mount at all
  - `:no_workspace` - no workspace is currently active
  """
  def create_page(parent_rel_path, name) do
    with {:ok, normalized_name} <- normalize_name(name),
         {:ok, mount} <- mount_root_for(parent_rel_path),
         root <- mount.root,
         mount_parent <- mount_relative(parent_rel_path),
         :ok <- check_parent_contained(root, mount_parent),
         parent_abs <- Path.join(root, mount_parent),
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

      write_string_to_file(abs, content) |> format_create_response(abs, mount)
    else
      {:error, :name_invalid} -> {:error, :name_invalid}
      {:error, reason} -> {:error, reason}
      true -> {:error, :already_exists}
    end
  end

  @doc """
  Creates a new folder in the given parent folder.

  `parent_rel_path` is a full workspace-relative path (`mounts/<name>` for
  the mount's own root, or `mounts/<name>/<subfolder>` beneath it).

  Returns `{:ok, %{path: rel_path}} | {:error, reason}` where `rel_path` is
  workspace-relative (`mounts/<name>/…`).

  Errors:
  - `:name_invalid` - name fails validation
  - `:already_exists` - a file or folder already exists at that path
  - `:outside_workspace` - path would escape the owning mount's root, or
    doesn't name a mount at all
  - `:no_workspace` - no workspace is currently active
  """
  def create_folder(parent_rel_path, name) do
    with {:ok, normalized_name} <- normalize_name(name),
         {:ok, mount} <- mount_root_for(parent_rel_path),
         root <- mount.root,
         mount_parent <- mount_relative(parent_rel_path),
         :ok <- check_parent_contained(root, mount_parent),
         parent_abs <- Path.join(root, mount_parent),
         :ok <- check_parent_is_directory(parent_abs),
         abs <- Path.join(parent_abs, normalized_name),
         {:ok, _} <- contain(root, Path.relative_to(abs, root)),
         false <- File.exists?(abs),
         :ok <- ensure_parent_directory(parent_abs),
         :ok <- create_directory(abs) do
      format_create_response({:ok, %{}}, abs, mount)
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

  defp format_create_response({:ok, _}, abs, mount) do
    rel = Path.relative_to(abs, mount.root)
    {:ok, %{path: to_workspace_rel(mount, rel)}}
  end

  defp format_create_response({:error, reason}, _abs, _mount) do
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
  `new_rel_path` is workspace-relative (`mounts/<name>/…`) and `names` are
  the display names of the workflows whose references were rewritten
  (deduplicated, sorted).

  If a workflow rewrite fails, returns `{:error, {:rewrite_failed, filename, reason}}`.
  Note: The file rename itself has already happened at this point; the filesystem
  is not rolled back. The error is returned to allow the user to decide how to
  proceed (e.g., via version control recovery or manual intervention).

  Errors:
  - `:name_invalid` - the new name fails validation
  - `:already_exists` - a file or folder already exists at the new path
  - `:not_found` - nothing exists at `rel_path`
  - `:outside_workspace` - a path would escape the owning mount's root, or
    doesn't name a mount at all
  - `:no_workspace` - no workspace is currently active
  - `{:rewrite_failed, filename, reason}` - a workflow reference rewrite failed
  """
  def rename(rel_path, new_name) do
    with {:ok, mount} <- mount_root_for(rel_path),
         root <- mount.root,
         mount_rel <- mount_relative(rel_path),
         {:ok, old_abs} <- contain(root, mount_rel),
         true <- File.exists?(old_abs),
         {:ok, normalized_name} <- normalize_name(new_name),
         is_dir <- File.dir?(old_abs),
         name_with_ext <- rename_target_name(is_dir, normalized_name),
         new_rel <- join_rel(parent_of(mount_rel), name_with_ext),
         {:ok, new_abs} <- contain(root, new_rel),
         false <- File.exists?(new_abs) do
      do_rename(root, mount_rel, new_rel, old_abs, new_abs, is_dir, mount)
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

  defp do_rename(root, old_rel, new_rel, old_abs, new_abs, true, mount) do
    # Collect every .md file under the folder — with its old and new
    # relative path — BEFORE moving anything on disk. Reference rewrites
    # then run per-file on the exact `icm/<child path>` string, so a
    # sibling folder whose name happens to start with the same prefix
    # (e.g. renaming "Offers" while "Offers Extra" also exists) is never
    # touched: its files were never in this collected list.
    child_pairs = collect_md_children(old_abs, root, old_rel, new_rel)
    File.rename!(old_abs, new_abs)

    # Workflows can also reference an entire folder via a wildcard glob
    # (`<folder>/*` — see `priv/workspace_template/icm/Workflows/*.md`),
    # which `collect_md_children` never surfaces (it only walks concrete
    # `.md` files that existed on disk at rename time). Rewrite that exact
    # `<old_rel>/*` needle too, via the same precision-safe full-string
    # mechanism as every other reference — the trailing `/*` keeps this from
    # ever matching a sibling folder's wildcard (e.g. "Offers" vs.
    # "Offers Extra").
    wildcard_pair = {old_rel <> "/*", new_rel <> "/*"}

    case rewrite_children(mount, child_pairs ++ [wildcard_pair]) do
      {:ok, updated_workflows} ->
        {:ok, %{path: to_workspace_rel(mount, new_rel), updated_workflows: updated_workflows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_rename(_root, old_rel, new_rel, old_abs, new_abs, false, mount) do
    File.rename!(old_abs, new_abs)

    case rewrite_children(mount, [{old_rel, new_rel}]) do
      {:ok, updated_workflows} ->
        {:ok, %{path: to_workspace_rel(mount, new_rel), updated_workflows: updated_workflows}}

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

  # `pairs` are mount-relative (the shape every other caller in this module
  # already works in). `References` (T4) takes workspace-relative
  # `mounts/<name>/…` paths — it resolves the owning mount itself, scoping
  # every scan/rewrite to that mount's own `Workflows/` — so each pair is
  # reattached to `mount` here before crossing that boundary.
  defp rewrite_children(mount, pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {old_rel, new_rel}, {:ok, names} ->
      old_ws_rel = to_workspace_rel(mount, old_rel)
      new_ws_rel = to_workspace_rel(mount, new_rel)
      {:ok, refs} = References.referencing_workflows(old_ws_rel)

      case References.rewrite(old_ws_rel, new_ws_rel) do
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
  - `:outside_workspace` - path would escape the owning mount's root, or
    doesn't name a mount at all
  - `:no_workspace` - no workspace is currently active
  """
  def delete(rel_path) do
    with {:ok, mount} <- mount_root_for(rel_path),
         {:ok, abs} <- contain(mount.root, mount_relative(rel_path)) do
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
