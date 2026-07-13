defmodule ValeaWeb.AgentsRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.AgentCase
  alias Valea.Workspace.Manager

  @wf_path "mounts/primary/Workflows/New Inquiry Triage.md"
  @disabled_wf_path "mounts/primary/Workflows/Weekly Admin Review.md"
  @input_path "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"

  # A fresh scaffold (T8) mints its own real mount from the template's rich
  # seed content (New Inquiry Triage, Weekly Admin Review, ...) at
  # `mounts/<slug-of-name>` — naming the workspace "Primary" lands it at
  # exactly `mounts/primary`, the path this whole suite exercises.
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

    # Legacy path-based `Manager.create/2` (v4, starter mount) — called
    # directly rather than through the `create_workspace` RPC, which is now
    # the C9 id-based surface (`Manager.create/1`, v5, no `mounts/`). This
    # suite exercises `mounts/primary/...` starter-mount content the
    # id-based create can't provide yet (Phase 3 introduces the
    # config-backed ICM registry) — see `Valea.Api.Workspace`'s moduledoc.
    parent = Path.join(dir, "workspaces")
    {:ok, _} = Manager.create(parent, "Primary")
    %{"data" => %{"generation" => generation}} = rpc("get_workspace", %{})

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

      pending_path = Path.join([parent, "Primary", "queue", "pending", run_id <> ".json"])
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

  describe "distill_decisions" do
    # `@wf_path`'s starter-mount slug is "primary" (this suite's `setup`
    # names the workspace "Primary" — see the file header comment). Since
    # Task B9, the starter mount seeds a real Distill Decisions contract at
    # this same path, so a freshly scaffolded workspace already has one;
    # `write_distill_workflow!/1` below overwrites it with scenario-specific
    # frontmatter/body where a test needs different content than the seed.
    @distill_wf_path "mounts/primary/Workflows/Distill Decisions.md"

    defp write_distill_workflow!(parent) do
      dir = Path.join([parent, "Primary", "mounts", "primary", "Workflows"])
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "Distill Decisions.md"),
        """
        ---
        enabled: true
        risk_level: medium
        approval:
          required: true
        ---
        # Distill Decisions

        ## Process

        1. Read the digest.
        """
      )
    end

    defp write_decided_item!(parent, dir, run_id, decided_at) do
      item = %{
        "schema" => "queue_item/v2",
        "run_id" => run_id,
        "workflow" => @wf_path,
        "risk_level" => "medium",
        "created_at" => "2026-07-01T00:00:00Z",
        "decided_at" => decided_at,
        "payload" => %{
          "title" => "T-" <> run_id,
          "summary" => "s",
          "kind" => "email_draft",
          "sources" => [],
          "proposed_action" => %{
            "type" => "create_email_draft",
            "to" => "a@b.c",
            "subject" => "s",
            "body_markdown" => "b"
          }
        }
      }

      d = Path.join([parent, "Primary", "queue", dir])
      File.mkdir_p!(d)
      File.write!(Path.join(d, run_id <> ".json"), Jason.encode!(item))
    end

    test "happy path returns run_id and session_id and eventually queues a proposal", %{
      generation: generation,
      parent: parent
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))
      write_distill_workflow!(parent)

      recent = DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.to_iso8601()
      write_decided_item!(parent, "approved", "d1", recent)

      assert %{"success" => true, "data" => %{"runId" => run_id, "sessionId" => session_id}} =
               rpc("distill_decisions", %{"generation" => generation}, ["runId", "sessionId"])

      assert is_binary(run_id)
      assert is_binary(session_id)

      input_path =
        Path.join([parent, "Primary", "queue", "staging", run_id, "input-decisions.md"])

      wait_until(fn -> File.exists?(input_path) end)
      assert File.read!(input_path) =~ "T-d1"

      pending_path = Path.join([parent, "Primary", "queue", "pending", run_id <> ".json"])
      wait_until(fn -> File.exists?(pending_path) end)
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc("distill_decisions", %{"generation" => generation - 1}, [
                 "runId",
                 "sessionId"
               ])

      assert inspect(errors) =~ "workspace_changed"
    end

    test "no distill contract installed surfaces workflow_not_found", %{
      generation: generation,
      parent: parent
    } do
      # Since Task B9 the starter mount seeds a real Distill Decisions
      # contract by default — remove it so this test still exercises the
      # genuinely-missing-contract branch of `distill_path/0`.
      File.rm!(Path.join([parent, "Primary", @distill_wf_path]))

      assert %{"success" => false, "errors" => errors} =
               rpc("distill_decisions", %{"generation" => generation}, ["runId", "sessionId"])

      assert inspect(errors) =~ "workflow_not_found"
    end

    test "an empty decisions window surfaces no_recent_decisions", %{
      generation: generation,
      parent: parent
    } do
      write_distill_workflow!(parent)

      assert %{"success" => false, "errors" => errors} =
               rpc("distill_decisions", %{"generation" => generation}, ["runId", "sessionId"])

      assert inspect(errors) =~ "no_recent_decisions"
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
                     "steps",
                     "mount"
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
      # A-T15: mount provenance (the owning mount's manifest display name) —
      # a fresh scaffold names the seeded mount after the workspace itself
      # ("Primary", per this suite's `setup`).
      assert triage["mount"] == "Primary"

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
