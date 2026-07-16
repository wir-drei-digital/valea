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

  # Line 1 of a session's transcript is its `session/v1` metadata (never a
  # timeline item) — the source of truth this suite reads to assert on
  # `kind`/`context_doc`/`input` without needing a live SessionServer.
  defp transcript_meta(workspace, id) do
    Path.join([workspace, "logs", "sessions", id <> ".jsonl"])
    |> File.stream!()
    |> Enum.at(0)
    |> Jason.decode!()
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
                 %{"mountKey" => icm.mount_key, "generation" => generation},
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
                 %{"mountKey" => "nope", "generation" => generation},
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
                 %{"mountKey" => icm.mount_key, "generation" => generation},
                 ["id"]
               )

      assert inspect(errors) =~ "harness_unavailable"
    end
  end

  # Spec D §B: `create_agent_session` no longer takes a `kind` argument (the
  # server always creates `kind: "chat"`) and gains two optional, raw
  # string-keyed locator maps — `context_doc` (validated + recorded, no
  # extra grant) and `input` (resolved to ONE exact read path, granted, and
  # returned as `input_path` so the FE can name exactly the file it
  # unlocked). Both fail closed: an unresolvable locator aborts session
  # creation entirely — never a session that silently lacks its context.
  describe "create_agent_session with context" do
    test "kind argument is gone; plain creation returns id and nil input_path, and the transcript records kind chat with nil context_doc/input",
         %{generation: generation, icm: icm, workspace: workspace} do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("happy"))

      assert %{"success" => true, "data" => %{"id" => id, "inputPath" => nil}} =
               rpc(
                 "create_agent_session",
                 %{"mountKey" => icm.mount_key, "generation" => generation},
                 ["id", "inputPath"]
               )

      on_exit(fn -> AgentCase.kill_session(id) end)

      assert %{"kind" => "chat", "context_doc" => nil, "input" => nil} =
               transcript_meta(workspace, id)
    end

    test "input locator is resolved, granted, and returned", %{
      generation: generation,
      icm: icm,
      workspace: workspace
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("happy"))

      msg_dir = Path.join([workspace, "sources", "mail", "messages"])
      File.mkdir_p!(msg_dir)
      File.write!(Path.join(msg_dir, "msg1.md"), "hello")

      input_locator = %{"kind" => "workspace", "path" => "sources/mail/messages/msg1.md"}

      assert %{"success" => true, "data" => %{"id" => id, "inputPath" => input_path}} =
               rpc(
                 "create_agent_session",
                 %{
                   "mountKey" => icm.mount_key,
                   "generation" => generation,
                   "input" => input_locator
                 },
                 ["id", "inputPath"]
               )

      on_exit(fn -> AgentCase.kill_session(id) end)

      assert input_path =~ "sources/mail/messages/msg1.md"
      assert %{"input" => ^input_locator} = transcript_meta(workspace, id)
    end

    test "missing input file fails closed — no session transcript file is created", %{
      generation: generation,
      icm: icm,
      workspace: workspace
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("happy"))

      sessions_dir = Path.join([workspace, "logs", "sessions"])
      before = if File.dir?(sessions_dir), do: File.ls!(sessions_dir), else: []

      input_locator = %{"kind" => "workspace", "path" => "sources/mail/messages/nope.md"}

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_agent_session",
                 %{
                   "mountKey" => icm.mount_key,
                   "generation" => generation,
                   "input" => input_locator
                 },
                 ["id", "inputPath"]
               )

      assert inspect(errors) =~ "input_unavailable"

      after_ls = if File.dir?(sessions_dir), do: File.ls!(sessions_dir), else: []
      assert after_ls == before
    end

    test "context_doc is validated and recorded; a missing one fails closed", %{
      generation: generation,
      icm: icm,
      workspace: workspace
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("happy"))

      File.mkdir_p!(Path.join(icm.root, "notes"))
      File.write!(Path.join(icm.root, "notes/plan.md"), "# Plan")

      context_doc = %{"kind" => "icm", "icm_id" => icm.id, "path" => "notes/plan.md"}

      assert %{"success" => true, "data" => %{"id" => id}} =
               rpc(
                 "create_agent_session",
                 %{
                   "mountKey" => icm.mount_key,
                   "generation" => generation,
                   "contextDoc" => context_doc
                 },
                 ["id", "inputPath"]
               )

      on_exit(fn -> AgentCase.kill_session(id) end)

      assert %{"context_doc" => ^context_doc} = transcript_meta(workspace, id)

      missing_context_doc = %{"kind" => "icm", "icm_id" => icm.id, "path" => "notes/missing.md"}

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_agent_session",
                 %{
                   "mountKey" => icm.mount_key,
                   "generation" => generation,
                   "contextDoc" => missing_context_doc
                 },
                 ["id", "inputPath"]
               )

      assert inspect(errors) =~ "context_doc_unavailable"
    end

    test "session_started audit entry carries the context fields", %{
      generation: generation,
      icm: icm,
      workspace: workspace
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("happy"))

      msg_dir = Path.join([workspace, "sources", "mail", "messages"])
      File.mkdir_p!(msg_dir)
      File.write!(Path.join(msg_dir, "msg1.md"), "hello")
      input_locator = %{"kind" => "workspace", "path" => "sources/mail/messages/msg1.md"}

      assert %{"success" => true, "data" => %{"id" => id}} =
               rpc(
                 "create_agent_session",
                 %{
                   "mountKey" => icm.mount_key,
                   "generation" => generation,
                   "input" => input_locator
                 },
                 ["id", "inputPath"]
               )

      on_exit(fn -> AgentCase.kill_session(id) end)

      assert {:ok, entries} = Valea.Audit.entries(10)

      assert Enum.any?(entries, fn e ->
               e["type"] == "session_started" and e["session_id"] == id and
                 e["mount_key"] == icm.mount_key and e["input"] == input_locator and
                 e["context_doc"] == nil
             end)
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
