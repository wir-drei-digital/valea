defmodule Valea.Api.ICM do
  @moduledoc """
  Data-layer-less Ash resource exposing the workspace's mounted ICM trees
  over RPC.

  Wraps `Valea.ICM`; converts its atom-keyed nodes into string-keyed maps
  and translates the `:no_workspace` reason into the frontend's
  `"workspace_not_open"` error string. `Valea.ICM.tree/0` (Task A-T3)
  returns a list of per-mount groups (`%{mount:, title:, root_rel:, tree:
  [...]}`) instead of a flat node list; the `:tree` action (Task A-T11)
  declares `constraints fields: [mounts: [...]]` on that OUTER shape —
  `mount`/`title`/`root_rel`/`tree` are typed, camelCase fields like every
  other `constraints fields: [...]` action below — while each per-node
  `tree` value stays unconstrained (no `items: [fields: ...]`; a
  `folder`/`page` node can nest arbitrarily deep via `:children`, which
  Ash's field-constraint system has no way to describe recursively).
  `stringify/1` below still walks that unconstrained `tree` list by hand,
  same as it always has for `:children` and for the unconstrained `:page`
  return.

  The write actions (`save_page`, `create_page`, `create_folder`, `rename`,
  `delete`, `references`) declare `constraints fields: [...]` on their `:map`
  return so ash_typescript emits typed TS interfaces instead of
  `Record<string, any>` (see Ash 3 `topics/actions/generic-actions.md`
  "Return types and constraints" and ash_typescript
  `advanced/custom-types.md` — "Maps with field constraints ... still generate
  typed objects"). The `:page` action stays unconstrained (Phase-1) but its
  return map now also carries `hash`, `prosemirror`, and `frontmatter`
  (Task 4). `frontmatter` rides along unchanged through the generic
  `to_string(k)` top-level stringify below — it's already a string-keyed map
  (parsed by `YamlElixir.read_from_string/1`, which returns string keys), and
  since the action is unconstrained, ash_typescript never walks into it to
  camelCase anything. That's intentional: frontmatter keys are user-authored
  YAML data (workflow contract fields like `risk_level`), not wire-format
  field names, and must be delivered to the frontend byte-for-byte raw.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("ICM")
  end

  alias Valea.Api.Error
  alias Valea.ICM.Search
  alias Valea.Mounts
  alias Valea.Workflows.MemoryProposal
  alias Valea.Workspace.Manager

  actions do
    action :tree, :map do
      constraints fields: [
                    mounts: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            mount: [type: :string, allow_nil?: false],
                            title: [type: :string, allow_nil?: false],
                            root_rel: [type: :string, allow_nil?: false],
                            # Unconstrained on purpose — see moduledoc.
                            tree: [type: {:array, :map}, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      run fn _input, _ctx ->
        case Valea.ICM.tree() do
          {:ok, groups} ->
            {:ok,
             %{
               mounts:
                 Enum.map(groups, fn %{mount: mount, title: title, root_rel: root_rel, tree: tree} ->
                   %{mount: mount, title: title, root_rel: root_rel, tree: stringify(tree)}
                 end)
             }}

          {:error, reason} ->
            {:error, error_for(reason)}
        end
      end
    end

    action :page, :map do
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        case Valea.ICM.page(input.arguments.path) do
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
        %{path: path, prosemirror: pm, base_hash: base_hash} = input.arguments
        # `Map.get/3` (not a destructure) — ash_typescript only puts keys the
        # caller actually sent into `input.arguments`, so an omitted optional
        # argument is ABSENT, not `nil`, despite the `default: nil` above.
        generation = Map.get(input.arguments, :generation)

        with :ok <- check_generation_if_present(generation),
             {:ok, %{hash: hash, saved_at: saved_at}} <- Valea.ICM.save_page(path, pm, base_hash) do
          {:ok, %{hash: hash, saved_at: saved_at}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :create_page, :map do
      constraints fields: [path: [type: :string, allow_nil?: false]]

      argument :parent_path, :string, allow_nil?: false, constraints: [allow_empty?: true]
      argument :name, :string, allow_nil?: false

      run fn input, _ctx ->
        case Valea.ICM.create_page(input.arguments.parent_path, input.arguments.name) do
          {:ok, %{path: path}} -> {:ok, %{path: path}}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :create_folder, :map do
      constraints fields: [path: [type: :string, allow_nil?: false]]

      argument :parent_path, :string, allow_nil?: false, constraints: [allow_empty?: true]
      argument :name, :string, allow_nil?: false

      run fn input, _ctx ->
        case Valea.ICM.create_folder(input.arguments.parent_path, input.arguments.name) do
          {:ok, %{path: path}} -> {:ok, %{path: path}}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :rename, :map do
      constraints fields: [
                    path: [type: :string, allow_nil?: false],
                    updated_workflows: [type: {:array, :string}, allow_nil?: false]
                  ]

      argument :path, :string, allow_nil?: false
      argument :new_name, :string, allow_nil?: false

      run fn input, _ctx ->
        case Valea.ICM.rename(input.arguments.path, input.arguments.new_name) do
          {:ok, %{path: path, updated_workflows: updated}} ->
            {:ok, %{path: path, updated_workflows: updated}}

          {:error, reason} ->
            {:error, error_for(reason)}
        end
      end
    end

    action :delete, :map do
      constraints fields: [deleted: [type: :boolean, allow_nil?: false]]

      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        case Valea.ICM.delete(input.arguments.path) do
          {:ok, %{deleted: deleted}} -> {:ok, %{deleted: deleted}}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :references, :map do
      constraints fields: [
                    workflows: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            file: [type: :string, allow_nil?: false],
                            name: [type: :string, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        case Valea.ICM.References.referencing_workflows(input.arguments.path) do
          {:ok, refs} ->
            {:ok, %{workflows: Enum.map(refs, &%{file: &1.file, name: &1.name})}}

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
      # Optional: filters `Mounts.enabled/1` down to the one named mount
      # BEFORE scanning (see `search_opts/2` below) — never taken as a
      # mount struct from the caller, only ever used to filter the
      # server's own enabled-mounts list, so a caller can't inject a
      # mount that isn't enabled.
      argument :mount, :string, allow_nil?: true, default: nil

      run fn input, _ctx ->
        case Manager.current() do
          {:ok, %{path: root}} ->
            mount_name = Map.get(input.arguments, :mount)

            {:ok, %{results: results, skipped: skipped}} =
              Search.search(root, input.arguments.query, search_opts(root, mount_name))

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

  # `nil` (no mount filter) leaves `Search.search/3` to default to every
  # enabled mount. A present `mount` name filters the server's OWN
  # `Mounts.enabled/1` list down to the (at most one) entry with that
  # name — a caller can only narrow the scan to a mount that is already
  # enabled; an unknown or disabled name filters to `[]` (search
  # trivially returns no results), never to a mount struct built from the
  # argument itself.
  defp search_opts(_root, nil), do: []

  defp search_opts(root, mount_name) do
    [mounts: root |> Mounts.enabled() |> Enum.filter(&(&1.name == mount_name))]
  end

  # A path "exists" only when it attributes to an ENABLED, non-degraded
  # mount AND its physical resolution stays inside that mount's root —
  # `MemoryProposal.check_target/2` (Spec B) already implements exactly
  # this containment; the only thing added here is the actual file-type
  # check. `check_target/2` never raises on malformed/unknown/traversal
  # input (shell paths, unknown mounts, `..` escapes all fall through to
  # `{:error, _}`), so this never needs a rescue — and never leaks the
  # resolved absolute path back to the caller, only the boolean.
  defp path_exists?(root, path) do
    case MemoryProposal.check_target(root, path) do
      {:ok, %{abs: abs}} -> File.regular?(abs)
      {:error, _reason} -> false
    end
  end
end
