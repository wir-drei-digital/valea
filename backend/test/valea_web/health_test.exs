defmodule ValeaWeb.HealthTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest

  @endpoint ValeaWeb.Endpoint

  test "GET /api/health" do
    conn = get(build_conn(), "/api/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
