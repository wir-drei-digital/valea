defmodule ValeaWeb.AgentsRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.AgentCase
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager

  @wf_path "mounts/primary/Workflows/New Inquiry Triage.md"
  @disabled_wf_path "mounts/primary/Workflows/Weekly Admin Review.md"
  @input_path "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"

  # The workspace template still scaffolds the legacy `icm/` tree until Task
  # A-T8 migrates it — a fresh scaffold has no `mounts/` dir at all, so
  # `Valea.Workflows` (mount-sourced, T5) sees nothing until one exists.
  # COPY (not move) the scaffolded `icm/` into `mounts/<name>/` and stamp a
  # manifest on it, mirroring `test/valea/icm_test.exs`'s `seed_mount!/3`.
  defp seed_mount!(ws_path, name, title) do
    mount_dir = Path.join([ws_path, "mounts", name])
    File.mkdir_p!(Path.dirname(mount_dir))
    File.cp_r!(Path.join(ws_path, "icm"), mount_dir)
    Manifest.write!(mount_dir, %{id: "id-" <> name, name: title, description: ""})
  end

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

    parent = Path.join(dir, "workspaces")
    rpc("create_workspace", %{"parentDir" => parent, "name" => "W"})
    %{"data" => %{"generation" => generation}} = rpc("get_workspace", %{})

    seed_mount!(Path.join(parent, "W"), "primary", "Primary")

    %{parent: parent, generation: generation}
  end

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  describe "create_agent_session" do
    test "happy path returns a session id and it shows up in list_agent_sessions", %{
      generation: generation
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("happy"))

      assert %{"success" => true, "data" => %{"id" => id}} =
               rpc("create_agent_session", %{"kind" => "chat", "generation" => generation}, [
                 "id"
               ])

      assert is_binary(id)
      on_exit(fn -> AgentCase.kill_session(id) end)

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

    test "a stale generation surfaces workspace_changed without starting a session", %{
      generation: generation
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("happy"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_agent_session",
                 %{"kind" => "chat", "generation" => generation - 1},
                 ["id"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end

    test "an unavailable harness surfaces harness_unavailable", %{generation: generation} do
      Valea.App.Config.set_harness_command(["no-such-binary-zzz"])

      assert %{"success" => false, "errors" => errors} =
               rpc("create_agent_session", %{"kind" => "chat", "generation" => generation}, [
                 "id"
               ])

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

  describe "run_workflow" do
    test "happy path returns run_id and session_id and eventually queues a proposal", %{
      generation: generation,
      parent: parent
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

      assert %{"success" => true, "data" => %{"runId" => run_id, "sessionId" => session_id}} =
               rpc(
                 "run_workflow",
                 %{"path" => @wf_path, "input" => @input_path, "generation" => generation},
                 ["runId", "sessionId"]
               )

      assert is_binary(run_id)
      assert is_binary(session_id)

      pending_path = Path.join([parent, "W", "queue", "pending", run_id <> ".json"])
      wait_until(fn -> File.exists?(pending_path) end)
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "run_workflow",
                 %{"path" => @wf_path, "input" => @input_path, "generation" => generation - 1},
                 ["runId", "sessionId"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end

    test "a disabled workflow surfaces workflow_disabled", %{generation: generation} do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "run_workflow",
                 %{
                   "path" => @disabled_wf_path,
                   "input" => @input_path,
                   "generation" => generation
                 },
                 ["runId", "sessionId"]
               )

      assert inspect(errors) =~ "workflow_disabled"
    end

    test "a missing input surfaces input_not_found", %{generation: generation} do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "run_workflow",
                 %{
                   "path" => @wf_path,
                   "input" => "sources/mail/normalized/does-not-exist.json",
                   "generation" => generation
                 },
                 ["runId", "sessionId"]
               )

      assert inspect(errors) =~ "input_not_found"
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

  describe "list_workflows" do
    test "flattens the seeded workflow contracts" do
      assert %{"success" => true, "data" => %{"workflows" => workflows}} =
               rpc("list_workflows", %{}, [
                 %{
                   "workflows" => [
                     "path",
                     "name",
                     "description",
                     "enabled",
                     "triggerSource",
                     "riskLevel",
                     "sourceCount",
                     "steps"
                   ]
                 }
               ])

      assert triage = Enum.find(workflows, &(&1["path"] == @wf_path))
      assert triage["name"] == "New Inquiry Triage"
      assert triage["enabled"] == true
      assert triage["triggerSource"] == "email.selected"
      assert triage["riskLevel"] == "medium"
      assert triage["sourceCount"] == 5
      assert is_list(triage["steps"])
      assert triage["steps"] != []

      assert weekly = Enum.find(workflows, &(&1["path"] == @disabled_wf_path))
      assert weekly["enabled"] == false
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(50)
        wait_until(fun, tries - 1)
    end
  end
end
