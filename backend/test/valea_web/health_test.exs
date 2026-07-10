defmodule ValeaWeb.HealthTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest

  @endpoint ValeaWeb.Endpoint

  test "GET /api/health" do
    conn = get(build_conn(), "/api/health")
    # nonce is null in dev/test (no VALEA_READY_NONCE set); the desktop shell
    # sets it per-launch and the readiness probe checks it matches.
    assert %{"status" => "ok", "nonce" => nil} = json_response(conn, 200)
  end
end
