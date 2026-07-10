defmodule ValeaWeb.Plugs.ControlToken do
  @moduledoc """
  Per-launch loopback control token. The desktop shell generates it and
  hands it to both the sidecar (env) and the SPA (init script); browsers
  on malicious origins can neither read it nor forge the header cross-
  origin. Requests without it get a 401 and no detail.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = ValeaWeb.ControlToken.expected()

    case get_req_header(conn, "x-valea-token") do
      [token] when is_binary(token) ->
        if Plug.Crypto.secure_compare(token, expected) do
          conn
        else
          halt_401(conn)
        end

      _ ->
        halt_401(conn)
    end
  end

  defp halt_401(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end

defmodule ValeaWeb.ControlToken do
  @moduledoc """
  Resolves the per-launch control token and readiness nonce from app env
  (populated by `config/runtime.exs`). `expected/0` raises if the token is
  unset so a misconfigured prod boot fails loudly rather than silently
  accepting every request.
  """
  def expected, do: Application.fetch_env!(:valea, :control_token)

  def ready_nonce, do: Application.get_env(:valea, :ready_nonce)
end
