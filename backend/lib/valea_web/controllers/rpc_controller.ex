defmodule ValeaWeb.RpcController do
  @moduledoc """
  HTTP entry point for the ash_typescript RPC surface. Delegates to
  `AshTypescript.Rpc` which introspects `Valea.Api` and runs the requested
  generic action, returning the `%{success:, data:|errors:}` envelope the
  generated TypeScript client expects.
  """
  use Phoenix.Controller, formats: [:json]

  def run(conn, params) do
    json(conn, AshTypescript.Rpc.run_action(:valea, conn, params))
  end

  def validate(conn, params) do
    json(conn, AshTypescript.Rpc.validate_action(:valea, conn, params))
  end
end
