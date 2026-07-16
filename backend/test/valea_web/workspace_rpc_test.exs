defmodule ValeaWeb.WorkspaceRpcTest do
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

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  # -- C9 id-based surface (Task 2.5) --------------------------------------

  describe "create_workspace / open_workspace / get_workspace / recent_workspaces (id-based)" do
    test "create_workspace takes only name and returns an id, never a path" do
      assert %{
               "success" => true,
               "data" => %{"open" => true, "name" => "Coaching business"} = data
             } =
               rpc("create_workspace", %{"name" => "Coaching business"})

      assert is_binary(data["id"])
      assert is_integer(data["generation"])
      refute Map.has_key?(data, "path")
    end

    test "open_workspace(id) reopens a previously created workspace by id" do
      assert %{"success" => true, "data" => %{"id" => id}} =
               rpc("create_workspace", %{"name" => "Legal"})

      assert %{"success" => true, "data" => %{"open" => false}} = rpc("close_workspace", %{})

      assert %{
               "success" => true,
               "data" => %{"open" => true, "id" => ^id, "name" => "Legal"} = data
             } =
               rpc("open_workspace", %{"id" => id})

      refute Map.has_key?(data, "path")
    end

    test "open_workspace(unknown id) surfaces unknown_workspace" do
      assert %{"success" => false, "errors" => errors} =
               rpc("open_workspace", %{"id" => "nope"})

      assert inspect(errors) =~ "unknown_workspace"
    end

    test "open_workspace(id, generation) rejects a stale generation before switching" do
      assert %{"success" => true, "data" => %{"id" => first_id, "generation" => generation}} =
               rpc("create_workspace", %{"name" => "First"})

      assert %{"success" => true, "data" => %{"id" => second_id}} =
               rpc("create_workspace", %{"name" => "Second"})

      assert %{"success" => false, "errors" => errors} =
               rpc("open_workspace", %{"id" => first_id, "generation" => generation})

      assert inspect(errors) =~ "workspace_changed"
      # The rejected switch never happened — still on "Second".
      assert %{"success" => true, "data" => %{"id" => ^second_id}} = rpc("get_workspace", %{})
    end

    test "get_workspace reports open: false, id: nil, name: nil when nothing is open" do
      assert %{"success" => true, "data" => %{"open" => false, "id" => nil, "name" => nil}} =
               rpc("get_workspace", %{})
    end

    test "recent_workspaces lists id/name/last_opened_at, never a path" do
      rpc("create_workspace", %{"name" => "Coaching business"})

      assert %{"success" => true, "data" => [entry | _]} = rpc("recent_workspaces", %{})
      assert entry["name"] == "Coaching business"
      assert is_binary(entry["id"])
      assert is_binary(entry["last_opened_at"])
      refute Map.has_key?(entry, "path")
    end
  end

  describe "workspace_switch_preflight" do
    test "an unknown id surfaces unknown_workspace" do
      assert %{"success" => false, "errors" => errors} =
               rpc("workspace_switch_preflight", %{"id" => "nope"})

      assert inspect(errors) =~ "unknown_workspace"
    end

    test "a self-switch (target == current) gracefully reports no live sessions" do
      assert %{"success" => true, "data" => %{"id" => id}} =
               rpc("create_workspace", %{"name" => "Self"})

      assert %{"success" => true, "data" => %{"target_id" => ^id, "live_sessions" => []}} =
               rpc("workspace_switch_preflight", %{"id" => id})
    end

    test "a different, known target reports empty live sessions when nothing is running" do
      assert %{"success" => true, "data" => %{"id" => _first_id}} =
               rpc("create_workspace", %{"name" => "First"})

      assert %{"success" => true, "data" => %{"id" => second_id}} =
               rpc("create_workspace", %{"name" => "Second"})

      assert %{"success" => true, "data" => %{"target_id" => ^second_id, "live_sessions" => []}} =
               rpc("workspace_switch_preflight", %{"id" => second_id})
    end
  end
end
