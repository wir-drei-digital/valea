defmodule Valea.Api.Queue do
  @moduledoc """
  Data-layer-less Ash resource exposing the proposal queue and the audit
  trail over RPC.

  Wraps `Valea.Queue` and `Valea.Audit`, following `Valea.Api.ICM`'s
  `constraints fields: [...]` pattern for typed actions. `get_item`'s
  `item` field and `list_audit_entries`'s `entries` field stay UNCONSTRAINED
  `:map` (no nested `fields:`) — a queue item envelope carries a
  workflow-authored `payload` and audit entries are heterogeneous by `type`
  — so both are delivered RAW (string keys, no camelCase translation) rather
  than reshaped into a fixed typed shape. This is the same
  typed-vs-unconstrained-map casing split documented in `Valea.Api.ICM`'s
  moduledoc, just applied field-by-field within an otherwise-typed action
  instead of to a whole action.

  Mutating actions (`approve_item`, `reject_item`) take a `generation`
  argument and guard with `Valea.Workspace.Manager.check_generation/1`
  before touching the queue filesystem.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Queue")
  end

  alias Valea.Api.Error
  alias Valea.Workspace.Manager

  actions do
    action :list_items, :map do
      constraints fields: [
                    items: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            run_id: [type: :string, allow_nil?: false],
                            title: [type: :string, allow_nil?: true],
                            summary: [type: :string, allow_nil?: true],
                            kind: [type: :string, allow_nil?: true],
                            risk_level: [type: :string, allow_nil?: true],
                            created_at: [type: :string, allow_nil?: true],
                            workflow: [type: :string, allow_nil?: true],
                            valid: [type: :boolean, allow_nil?: false],
                            error: [type: :string, allow_nil?: true]
                          ]
                        ]
                      ]
                    ]
                  ]

      run fn _input, _ctx ->
        case Valea.Queue.list() do
          {:ok, items} -> {:ok, %{items: Enum.map(items, &normalize_item/1)}}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :get_item, :map do
      constraints fields: [
                    item: [type: :map, allow_nil?: false],
                    revision: [type: :string, allow_nil?: false]
                  ]

      argument :run_id, :string, allow_nil?: false

      run fn input, _ctx ->
        case Valea.Queue.get(input.arguments.run_id) do
          {:ok, %{item: item, revision: revision}} -> {:ok, %{item: item, revision: revision}}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :approve_item, :map do
      constraints fields: [draft_path: [type: :string, allow_nil?: false]]

      argument :run_id, :string, allow_nil?: false
      argument :revision, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{run_id: run_id, revision: revision, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{draft_path: draft_path}} <- Valea.Queue.approve(run_id, revision) do
          {:ok, %{draft_path: draft_path}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :reject_item, :map do
      constraints fields: [rejected: [type: :boolean, allow_nil?: false]]

      argument :run_id, :string, allow_nil?: false
      argument :revision, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{run_id: run_id, revision: revision, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{}} <- Valea.Queue.reject(run_id, revision) do
          # STRING key — see `Valea.Api.Agents.harness_doctor`'s note: a
          # top-level generic-action `:map` boolean field goes through
          # ash_typescript's untyped-map extraction fallback, which nulls out
          # a legitimate `false` unless the map has no atom key to falsely
          # "succeed" the first (buggy) lookup. `rejected` is always `true`
          # today (failure paths return `{:error, _}` instead), but this
          # keeps the field correct if that ever changes.
          {:ok, %{"rejected" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :list_audit_entries, :map do
      constraints fields: [entries: [type: {:array, :map}, allow_nil?: false]]

      argument :limit, :integer, allow_nil?: false

      run fn input, _ctx ->
        {:ok, entries} = Valea.Audit.entries(input.arguments.limit)
        {:ok, %{entries: entries}}
      end
    end
  end

  @doc false
  # Central error mapping for every action in this resource — mirrors
  # `Valea.Api.ICM.error_for/1`. `:no_workspace` becomes the frontend's
  # `"workspace_not_open"`; the queue/generation atoms this resource's
  # dependencies return (`:queue_item_gone`, `:queue_item_invalid`,
  # `:queue_item_changed`, `:workspace_changed`) already stringify to the
  # exact code the frontend expects.
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  def error_for(reason), do: Error.new(inspect(reason))

  # `Valea.Queue.list/0`'s valid entries have no `:error` key at all (only
  # invalid entries carry one) — typed action returns need every constrained
  # field present, so this fills it in as `nil` rather than omitting it.
  defp normalize_item(item), do: Map.put_new(item, :error, nil)
end
