defmodule Valea.Api.Error do
  @moduledoc """
  A Splode error for RPC actions that carries a single machine-readable
  string the frontend matches on (e.g. `"workspace_not_open"`,
  `"workspace_changed"` — the latter surfaces `Valea.Workspace.Manager.check_generation/1`
  rejecting an action against a stale workspace generation).

  Generic Ash actions that return a plain `{:error, "string"}` surface through
  ash_typescript as a generic "unknown_error" with the message discarded, so
  the frontend can't distinguish preconditions like a closed workspace. Wrapping
  the string in this error and implementing `AshTypescript.Rpc.Error` (per
  ash_typescript's error-handling guide) preserves the string as both the
  error `type` and `message`.
  """
  use Splode.Error, fields: [:code], class: :invalid

  @doc "Builds the error from a machine-readable code string."
  def new(code) when is_binary(code), do: exception(code: code)

  def message(%{code: code}), do: code
end

defimpl AshTypescript.Rpc.Error, for: Valea.Api.Error do
  def to_error(%{code: code}) do
    %{
      message: code,
      short_message: code,
      type: code,
      vars: %{},
      fields: [],
      path: []
    }
  end
end
