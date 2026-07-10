defmodule ValeaWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    json(conn, %{status: "ok", nonce: ValeaWeb.ControlToken.ready_nonce()})
  end
end
