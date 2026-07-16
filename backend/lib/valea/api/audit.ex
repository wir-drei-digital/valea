defmodule Valea.Api.Audit do
  @moduledoc """
  Data-layer-less Ash resource exposing the audit log over RPC.

  Relocated from the deleted `Valea.Api.Queue` (Spec D §A): `Valea.Audit`
  is queue-independent (a `Valea.Workspace.Runtime` child writing
  `logs/audit.jsonl`), so its RPC surface survives the queue deletion.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Audit")
  end

  actions do
    action :list_audit_entries, :map do
      constraints fields: [entries: [type: {:array, :map}, allow_nil?: false]]

      argument :limit, :integer, allow_nil?: false

      run fn input, _ctx ->
        {:ok, entries} = Valea.Audit.entries(input.arguments.limit)
        {:ok, %{entries: entries}}
      end
    end
  end
end
