defmodule ValeaWeb.RpcChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint ValeaWeb.Endpoint

  test "runs an rpc action over the channel" do
    {:ok, _, socket} =
      socket(ValeaWeb.UserSocket, nil, %{})
      |> subscribe_and_join(ValeaWeb.RpcChannel, "ash_typescript_rpc:client")

    ref = push(socket, "run", %{"action" => "cockpit_today", "input" => %{}, "fields" => []})
    assert_reply ref, :ok, reply
    assert reply[:success] || reply["success"]
  end

  test "replies with an error for an unknown event instead of crashing" do
    {:ok, _, socket} =
      socket(ValeaWeb.UserSocket, nil, %{})
      |> subscribe_and_join(ValeaWeb.RpcChannel, "ash_typescript_rpc:client")

    ref = push(socket, "bogus_event", %{})
    assert_reply ref, :error, %{reason: "unknown event: bogus_event"}
  end
end
