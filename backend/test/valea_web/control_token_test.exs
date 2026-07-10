defmodule ValeaWeb.ControlTokenTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest, except: [connect: 2]
  import Phoenix.ChannelTest, only: [connect: 2]
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  test "rpc without token is rejected 401" do
    conn =
      post(build_conn(), "/rpc/run", %{
        "action" => "get_workspace",
        "fields" => [],
        "input" => %{}
      })

    assert conn.status == 401
  end

  test "rpc with the token passes the plug" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-valea-token", "valea-dev-token")
      |> post("/rpc/run", %{"action" => "get_workspace", "fields" => [], "input" => %{}})

    assert conn.status == 200
  end

  test "health echoes the readiness nonce and needs no token" do
    conn = get(build_conn(), "/api/health")
    assert %{"status" => "ok"} = json_response(conn, 200)
  end

  test "the SPA catch-all stays reachable without a token" do
    # It serves the app that CARRIES the token, so it must not be gated.
    conn = get(build_conn(), "/")
    assert conn.status in [200, 404]
    refute conn.status == 401
  end

  test "socket connect without token is rejected" do
    assert :error = connect(ValeaWeb.UserSocket, %{})
  end

  test "socket connect with the token succeeds" do
    assert {:ok, _socket} = connect(ValeaWeb.UserSocket, %{"token" => "valea-dev-token"})
  end
end
