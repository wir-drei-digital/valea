defmodule ValeaWeb.AgentsRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.AgentCase

  # Post-task-3.2, `Valea.Mounts.list/1` is config truth over `icms:` ONLY —
  # a freshly scaffolded workspace carries no seeded mount, and every mount
  # is now EXTERNAL. So this suite mounts a REAL external ICM
  # (`AgentCase.mount_test_icm!/2`) to exercise `create_agent_session`
  # against a real `mount_key`/`icm.root`.
  setup do
    ws = AgentCase.open_workspace!("Primary")
    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")

    %{"data" => %{"generation" => generation}} = rpc("get_workspace", %{})

    %{workspace: ws.path, generation: generation, icm: icm}
  end

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  describe "create_agent_session" do
    test "happy path returns a session id, launches inside the named mount's ICM, and shows up in list_agent_sessions",
         %{
           generation: generation,
           icm: icm
         } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("happy"))

      assert %{"success" => true, "data" => %{"id" => id}} =
               rpc(
                 "create_agent_session",
                 %{"kind" => "chat", "mountKey" => icm.mount_key, "generation" => generation},
                 ["id"]
               )

      assert is_binary(id)
      on_exit(fn -> AgentCase.kill_session(id) end)

      # Task 5.5: `create_session` resolves a `SessionScope` for `mountKey`
      # and launches the session with cwd = that mount's own ICM root —
      # never the workspace, never a caller-chosen path.
      pid = GenServer.whereis({:via, Registry, {Valea.Agents.SessionRegistry, id}})
      assert :sys.get_state(pid).policy_ctx.cwd == icm.root

      assert %{"success" => true, "data" => %{"sessions" => sessions}} =
               rpc("list_agent_sessions", %{}, [
                 %{
                   "sessions" => [
                     "id",
                     "kind",
                     "title",
                     "workflow",
                     "runId",
                     "startedAt",
                     "status",
                     "live"
                   ]
                 }
               ])

      assert session = Enum.find(sessions, &(&1["id"] == id))
      assert session["kind"] == "chat"
      assert session["title"] == "New session"
      assert session["workflow"] == nil
      assert session["runId"] == nil
      assert session["live"] == true
      assert is_binary(session["startedAt"])
    end

    test "an unknown mount_key surfaces icm_unavailable without starting a session", %{
      generation: generation
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("happy"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_agent_session",
                 %{"kind" => "chat", "mountKey" => "nope", "generation" => generation},
                 ["id"]
               )

      assert inspect(errors) =~ "icm_unavailable"
    end

    test "a stale generation surfaces workspace_changed without starting a session", %{
      generation: generation,
      icm: icm
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("happy"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_agent_session",
                 %{
                   "kind" => "chat",
                   "mountKey" => icm.mount_key,
                   "generation" => generation - 1
                 },
                 ["id"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end

    test "an unavailable harness surfaces harness_unavailable", %{
      generation: generation,
      icm: icm
    } do
      Valea.App.Config.set_harness_command(["no-such-binary-zzz"])

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_agent_session",
                 %{"kind" => "chat", "mountKey" => icm.mount_key, "generation" => generation},
                 ["id"]
               )

      assert inspect(errors) =~ "harness_unavailable"
    end
  end

  describe "list_agent_sessions" do
    test "returns an empty list when no sessions exist" do
      assert %{"success" => true, "data" => %{"sessions" => []}} =
               rpc("list_agent_sessions", %{}, [
                 %{
                   "sessions" => [
                     "id",
                     "kind",
                     "title",
                     "workflow",
                     "runId",
                     "startedAt",
                     "status",
                     "live"
                   ]
                 }
               ])
    end
  end

  describe "harness_doctor" do
    test "returns three checks shaped id/status/detail/remedy" do
      assert %{"success" => true, "data" => %{"ok" => ok, "checks" => checks}} =
               rpc("harness_doctor", %{}, [
                 "ok",
                 %{"checks" => ["id", "status", "detail", "remedy"]}
               ])

      assert is_boolean(ok)
      assert length(checks) == 3

      assert Enum.all?(
               checks,
               &(is_binary(&1["id"]) and is_binary(&1["status"]) and is_binary(&1["detail"]))
             )

      assert Enum.all?(checks, &(&1["remedy"] == nil or is_binary(&1["remedy"])))
    end
  end
end
