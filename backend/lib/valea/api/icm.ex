defmodule Valea.Api.ICM do
  @moduledoc """
  Data-layer-less Ash resource exposing ONE ICM at a time over RPC, keyed
  by `mount_key` (the `icms:` config key) + a path relative to that ICM's
  own root (task 4.2's re-key — see `Valea.ICM`'s own moduledoc). Every
  action below wraps the matching `Valea.ICM` function 1:1 and converts its
  atom-keyed return into a string-keyed map; `error_for/1` translates the
  `:no_workspace` reason into the frontend's `"workspace_not_open"` error
  string.

  `:tree` (RPC name `icm_tree`) replaces the old grouped-all-mounts
  `Valea.ICM.tree/0` result with a single ICM's `%{mount_key:, title:,
  tree:}` (`Valea.ICM.tree_for/1`) — a caller that needs every enabled
  mount's tree fetches the mount list itself (`Valea.Api.Icms`'s
  `list_icms`) and calls this once per mount key. It guards `generation`
  the same way `Valea.Api.Icms`'s `list_icms` does (Task 3.4's
  moduledoc) — it reads LIVE filesystem/manifest state, not a cached
  value, so a stale `generation` short-circuits to `workspace_changed`
  before touching the filesystem.

  The write actions (`save_page`, `create_page`, `create_folder`, `rename`,
  `delete`, `references`) declare `constraints fields: [...]` on their `:map`
  return so ash_typescript emits typed TS interfaces instead of
  `Record<string, any>` (see Ash 3 `topics/actions/generic-actions.md`
  "Return types and constraints" and ash_typescript
  `advanced/custom-types.md` — "Maps with field constraints ... still generate
  typed objects"). The `:page` action stays unconstrained (Phase-1) but its
  return map now also carries `hash`, `prosemirror`, and `frontmatter` (Task
  4). `frontmatter` rides along unchanged through the generic `to_string(k)`
  top-level stringify below — it's already a string-keyed map (parsed by
  `YamlElixir.read_from_string/1`, which returns string keys), and since the
  action is unconstrained, ash_typescript never walks into it to camelCase
  anything. That's intentional: frontmatter keys are user-authored YAML data
  (workflow contract fields like `risk_level`), not wire-format field names,
  and must be delivered to the frontend byte-for-byte raw.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("ICM")
  end

  alias Valea.Api.Error
  alias Valea.ICM.{Backlinks, Search}
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  actions do
    action :tree, :map do
      constraints fields: [
                    mount_key: [type: :string, allow_nil?: false],
                    title: [type: :string, allow_nil?: false],
                    # Unconstrained on purpose — see moduledoc.
                    tree: [type: {:array, :map}, allow_nil?: false]
                  ]

      argument :mount_key, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{mount_key: mk, title: title, tree: tree}} <- Valea.ICM.tree_for(mount_key) do
          {:ok, %{mount_key: mk, title: title, tree: stringify(tree)}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :page, :map do
      argument :mount_key, :string, allow_nil?: false
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, path: path} = input.arguments

        case Valea.ICM.page(mount_key, path) do
          {:ok, page} -> {:ok, Map.new(page, fn {k, v} -> {to_string(k), v} end)}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :save_page, :map do
      constraints fields: [
                    hash: [type: :string, allow_nil?: false],
                    saved_at: [type: :string, allow_nil?: false]
                  ]

      argument :mount_key, :string, allow_nil?: false
      argument :path, :string, allow_nil?: false
      argument :prosemirror, :map, allow_nil?: false
      argument :base_hash, :string, allow_nil?: false
      # Optional so the editor store can adopt the generation guard (T21)
      # without a second codegen round: `nil` (the pre-T15 caller shape)
      # skips the check entirely; once present, a stale generation is
      # rejected BEFORE the write via `check_generation/1` — same guard the
      # Agents/Queue mutating actions use, just optional here for transition
      # compatibility.
      argument :generation, :integer, allow_nil?: true, default: nil

      run fn input, _ctx ->
        %{mount_key: mount_key, path: path, prosemirror: pm, base_hash: base_hash} =
          input.arguments

        # `Map.get/3` (not a destructure) — ash_typescript only puts keys the
        # caller actually sent into `input.arguments`, so an omitted optional
        # argument is ABSENT, not `nil`, despite the `default: nil` above.
        generation = Map.get(input.arguments, :generation)

        with :ok <- check_generation_if_present(generation),
             {:ok, %{hash: hash, saved_at: saved_at}} <-
               Valea.ICM.save_page(mount_key, path, pm, base_hash) do
          {:ok, %{hash: hash, saved_at: saved_at}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :create_page, :map do
      constraints fields: [path: [type: :string, allow_nil?: false]]

      argument :mount_key, :string, allow_nil?: false
      argument :parent_path, :string, allow_nil?: false, constraints: [allow_empty?: true]
      argument :name, :string, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, parent_path: parent_path, name: name} = input.arguments

        case Valea.ICM.create_page(mount_key, parent_path, name) do
          {:ok, %{path: path}} -> {:ok, %{path: path}}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :create_page_from_template, :map do
      constraints fields: [path: [type: :string, allow_nil?: false]]

      argument :mount_key, :string, allow_nil?: false
      argument :parent_path, :string, allow_nil?: false, constraints: [allow_empty?: true]
      argument :name, :string, allow_nil?: false
      argument :template_mount_key, :string, allow_nil?: false
      argument :template_path, :string, allow_nil?: false

      run fn input, _ctx ->
        %{
          mount_key: mount_key,
          parent_path: parent_path,
          name: name,
          template_mount_key: template_mount_key,
          template_path: template_path
        } = input.arguments

        case Valea.ICM.create_page_from_template(
               mount_key,
               parent_path,
               name,
               template_mount_key,
               template_path
             ) do
          {:ok, %{path: path}} -> {:ok, %{path: path}}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :create_folder, :map do
      constraints fields: [path: [type: :string, allow_nil?: false]]

      argument :mount_key, :string, allow_nil?: false
      argument :parent_path, :string, allow_nil?: false, constraints: [allow_empty?: true]
      argument :name, :string, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, parent_path: parent_path, name: name} = input.arguments

        case Valea.ICM.create_folder(mount_key, parent_path, name) do
          {:ok, %{path: path}} -> {:ok, %{path: path}}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :rename, :map do
      constraints fields: [
                    path: [type: :string, allow_nil?: false],
                    updated_pages: [type: {:array, :string}, allow_nil?: false]
                  ]

      argument :mount_key, :string, allow_nil?: false
      argument :path, :string, allow_nil?: false
      argument :new_name, :string, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, path: path, new_name: new_name} = input.arguments

        case Valea.ICM.rename(mount_key, path, new_name) do
          {:ok, %{path: path, updated_pages: pages}} ->
            {:ok, %{path: path, updated_pages: pages}}

          {:error, reason} ->
            {:error, error_for(reason)}
        end
      end
    end

    action :delete, :map do
      constraints fields: [deleted: [type: :boolean, allow_nil?: false]]

      argument :mount_key, :string, allow_nil?: false
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, path: path} = input.arguments

        case Valea.ICM.delete(mount_key, path) do
          {:ok, %{deleted: deleted}} -> {:ok, %{deleted: deleted}}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :references, :map do
      constraints fields: [
                    pages: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            source_path: [type: :string, allow_nil?: false],
                            mount: [type: :string, allow_nil?: false],
                            link_text: [type: :string, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :mount_key, :string, allow_nil?: false
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, path: path} = input.arguments

        case Backlinks.backlinks(mount_key, path) do
          {:ok, pages} ->
            {:ok,
             %{
               pages:
                 Enum.map(pages, fn p ->
                   %{source_path: p.source_path, mount: p.mount, link_text: p.link_text}
                 end)
             }}

          {:error, reason} ->
            {:error, error_for(reason)}
        end
      end
    end

    action :search, :map do
      constraints fields: [
                    results: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            path: [type: :string, allow_nil?: false],
                            mount: [type: :string, allow_nil?: false],
                            title: [type: :string, allow_nil?: false],
                            snippet: [type: :string, allow_nil?: false],
                            terms: [type: {:array, :string}, allow_nil?: false]
                          ]
                        ]
                      ]
                    ],
                    skipped: [type: {:array, :string}, allow_nil?: false]
                  ]

      argument :query, :string, allow_nil?: false
      # Optional: the PRIMARY ICM's mount_key (Task 5.6) — never taken as a
      # mount struct or a root path from the caller, only ever passed
      # through to `Search.search/4`, which resolves it against the
      # server's OWN mount table (`Valea.Mounts.scoped_roots/2`) so a
      # caller can't inject scope beyond what that ICM's own `CONTEXT.md`
      # actually declares related. `nil` preserves the pre-5.6 default —
      # every enabled mount — for the not-yet-ICM-scoped global palette.
      argument :mount_key, :string, allow_nil?: true, default: nil

      run fn input, _ctx ->
        case Manager.current() do
          {:ok, %{path: root}} ->
            mount_key = Map.get(input.arguments, :mount_key)

            {:ok, %{results: results, skipped: skipped}} =
              Search.search(root, input.arguments.query, mount_key)

            {:ok, %{results: results, skipped: skipped}}

          {:error, reason} ->
            {:error, error_for(reason)}
        end
      end
    end

    action :paths_exist, :map do
      constraints fields: [
                    results: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            path: [type: :string, allow_nil?: false],
                            exists: [type: :boolean, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :paths, {:array, :string}, allow_nil?: false

      run fn input, _ctx ->
        case Manager.current() do
          {:ok, %{path: root}} ->
            results =
              Enum.map(input.arguments.paths, fn path ->
                %{path: path, exists: path_exists?(root, path)}
              end)

            {:ok, %{results: results}}

          {:error, reason} ->
            {:error, error_for(reason)}
        end
      end
    end
  end

  @doc false
  # Central error mapping for every action in this resource. `:no_workspace`
  # becomes the frontend's `"workspace_not_open"` code; other atoms stringify;
  # anything else (tuple reasons like `{:conversion_failed, msg}` or
  # `{:rewrite_failed, file, reason}`) is `inspect/1`ed — `to_string/1` raises
  # Protocol.UndefinedError on tuples, so it must never be used here.
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  def error_for(reason), do: Error.new(inspect(reason))

  # `nil` (no generation supplied) skips the check entirely — see the
  # `save_page` argument doc above.
  defp check_generation_if_present(nil), do: :ok
  defp check_generation_if_present(generation), do: Manager.check_generation(generation)

  defp stringify(nodes) when is_list(nodes), do: Enum.map(nodes, &stringify/1)

  defp stringify(%{} = node) do
    Map.new(node, fn
      {:children, children} -> {"children", stringify(children)}
      {:type, t} -> {"type", to_string(t)}
      {k, v} -> {to_string(k), v}
    end)
  end

  # A path "exists" only when it attributes to an ENABLED, non-degraded
  # mount AND its physical resolution stays inside that mount's root —
  # `contained_target/2` (Spec B) already implements exactly this
  # containment; the only thing added here is the actual file-type check.
  # `contained_target/2` never raises on malformed/unknown/traversal input
  # (shell paths, unknown mounts, `..` escapes all fall through to
  # `{:error, _}`), so this never needs a rescue — and never leaks the
  # resolved absolute path back to the caller, only the boolean.
  defp path_exists?(root, path) do
    case contained_target(root, path) do
      {:ok, %{abs: abs}} -> File.regular?(abs)
      {:error, _reason} -> false
    end
  end

  @doc false
  # Server-owned containment: the target must attribute to an ENABLED,
  # non-degraded mount, and its physical resolution must stay inside that
  # mount's root (create targets may not exist yet — resolve_real appends
  # the missing remainder literally but still applies `..` physically).
  # Returns the lexical absolute path to write.
  @spec contained_target(String.t(), String.t()) ::
          {:ok, %{mount: map(), abs: String.t()}}
          | {:error, :not_in_mount | :mount_not_enabled | :outside_mount}
  defp contained_target(workspace, target_path) do
    case find_mount(workspace, target_path) do
      nil ->
        {:error, :not_in_mount}

      %{enabled: true, degraded: nil, root: root} = mount ->
        abs = target_abs(workspace, target_path)

        with true <- String.starts_with?(abs, root <> "/"),
             {:ok, _real} <- Valea.Paths.resolve_real(abs, root) do
          {:ok, %{mount: mount, abs: abs}}
        else
          _ -> {:error, :outside_mount}
        end

      _mount ->
        {:error, :mount_not_enabled}
    end
  end

  # `Mounts.mount_for/2` attributes a path ONLY among EFFECTIVE (enabled AND
  # non-degraded) mounts by design (see its own moduledoc) — a DISABLED
  # mount is filtered out right alongside a degraded one, so it can never
  # be the mount `mount_for/2` returns. That collapses the `_mount ->
  # {:error, :mount_not_enabled}` clause above into dead code: this
  # function needs to tell "names a real, healthy mount that happens to be
  # disabled" apart from "names no mount at all," which `mount_for/2`'s
  # contract cannot give it. So attribution here is independent —
  # `Mounts.list/1` filtered to non-degraded entries only (mirroring
  # `Mounts.mount_for/2`'s own segment-boundary, most-specific-root
  # logic), deliberately WITHOUT the `enabled` filter, so a disabled
  # mount is still attributed (and rejected with the specific
  # `:mount_not_enabled` reason above) rather than masquerading as
  # "not in any mount." A degraded mount's root stays excluded — same
  # untrusted-root reasoning as `Mounts.mount_for/2`.
  defp find_mount(workspace, target_path) do
    workspace
    |> Mounts.list()
    # `kind: :icm` only (Task 14): a synthetic mail mount must never be a
    # writable editor target — mail's agent-writable surface is governed
    # by `Valea.Agents.PermissionPolicy`'s mail tier, and the editor's
    # mutation RPCs address ICM content exclusively.
    |> Enum.filter(
      &(&1.kind == :icm and &1.degraded == nil and mount_prefix?(target_path, &1.root))
    )
    |> most_specific_root()
  end

  defp most_specific_root([]), do: nil
  defp most_specific_root(matches), do: Enum.max_by(matches, &byte_size(&1.root))

  defp mount_prefix?(path, root) do
    root != "" and (path == root or String.starts_with?(path <> "/", root <> "/"))
  end

  defp target_abs(_workspace, "/" <> _ = abs), do: Path.expand(abs)
  defp target_abs(workspace, rel), do: Path.expand(rel, workspace)
end
