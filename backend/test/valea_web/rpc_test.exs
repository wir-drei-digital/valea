defmodule ValeaWeb.RpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{parent: Path.join(dir, "workspaces")}
  end

  defp rpc(action, input) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => []})
    |> json_response(200)
  end

  test "get_workspace reports closed, then open after create_workspace", %{parent: parent} do
    assert %{"success" => true, "data" => %{"open" => false}} = rpc("get_workspace", %{})

    assert %{"success" => true, "data" => %{"open" => true, "name" => "W"}} =
             rpc("create_workspace", %{"parentDir" => parent, "name" => "W"})

    assert %{"success" => true, "data" => %{"open" => true}} = rpc("get_workspace", %{})
  end

  test "icm_tree requires a workspace" do
    assert %{"success" => false, "errors" => errors} = rpc("icm_tree", %{})
    assert inspect(errors) =~ "workspace_not_open"
  end

  test "icm_tree and cockpit_today succeed with a workspace open", %{parent: parent} do
    rpc("create_workspace", %{"parentDir" => parent, "name" => "W"})

    assert %{"success" => true, "data" => %{"nodes" => nodes}} = rpc("icm_tree", %{})
    assert Enum.any?(nodes, &(&1["name"] == "Offers"))

    assert %{"success" => true, "data" => %{"greeting" => "Good morning, Mara."}} =
             rpc("cockpit_today", %{})
  end
end
