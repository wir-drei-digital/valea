defmodule Valea.Api.ICM do
  @moduledoc """
  Data-layer-less Ash resource exposing the workspace icm/ tree over RPC.

  Wraps `Valea.ICM`; converts its atom-keyed nodes into string-keyed maps
  and translates the `:no_workspace` reason into the frontend's
  `"workspace_not_open"` error string.

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

  actions do
    action :tree, :map do
      run fn _input, _ctx ->
        case Valea.ICM.tree() do
          {:ok, nodes} -> {:ok, %{"nodes" => stringify(nodes)}}
          {:error, reason} -> {:error, error_for(reason)}
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

      run fn input, _ctx ->
        %{path: path, prosemirror: pm, base_hash: base_hash} = input.arguments

        case Valea.ICM.save_page(path, pm, base_hash) do
          {:ok, %{hash: hash, saved_at: saved_at}} ->
            {:ok, %{hash: hash, saved_at: saved_at}}

          {:error, reason} ->
            {:error, error_for(reason)}
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

  defp stringify(nodes) when is_list(nodes), do: Enum.map(nodes, &stringify/1)

  defp stringify(%{} = node) do
    Map.new(node, fn
      {:children, children} -> {"children", stringify(children)}
      {:type, t} -> {"type", to_string(t)}
      {k, v} -> {to_string(k), v}
    end)
  end
end
