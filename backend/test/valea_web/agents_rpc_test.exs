defmodule ValeaWeb.AgentsRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.AgentCase

  @input_path "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"

  # Verbatim from the legacy starter's rich seed content
  # (priv/legacy_workspace_template/mounts/starter/Workflows/) — this suite
  # exercises `run_workflow`/`distill_decisions`/`list_workflows` against
  # this same content, seeded into a REAL external ICM (see `setup` below)
  # rather than relying on the legacy scaffold's now-unregistered
  # `mounts/primary/` folder.
  @new_inquiry_triage """
  ---
  enabled: true
  trigger: { type: manual, source: email.selected }
  sources:
    - { id: current_email, type: email, required: true }
    - { id: founder_coaching_offer, type: icm, path: "Offers/Founder Coaching Package.md" }
    - { id: tone_guide, type: icm, path: "Tone & Voice/Email Tone Guide.md" }
    - { id: no_medical_advice, type: icm, path: "Policies/No Medical Advice.md" }
    - { id: pricing, type: icm, path: "Pricing/Current Pricing.md" }
  risk_level: medium
  approval:
    required: true
    reason: Email replies must be reviewed before sending.
    actions: [create_email_draft, apply_page_content]
  audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
  ---
  # New Inquiry Triage

  Classifies a new email inquiry and drafts a reply for review.

  ## Process

  1. Summarize the incoming inquiry in two sentences.
  2. Classify it: good-fit, unclear, not fit, or spam.
  3. Draft a warm reply using the tone guide and the relevant offer.

  ## Outputs

  One `proposal/v1` file at the exact path the run names, with `kind: "email_draft"`. Do not send anything.
  """

  @weekly_admin_review """
  ---
  enabled: false
  trigger: { type: manual, source: schedule.weekly }
  sources:
    - { id: open_queue, type: queue, required: true }
  risk_level: low
  approval:
    required: true
    reason: The weekly review is read by the owner before anything changes.
    actions: [create_brief]
  audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
  ---
  # Weekly Admin Review

  Summarizes the week's open loops for the owner. Not active yet.

  ## Outputs

  One `proposal/v1` file at the exact path the run names. Do not send anything.
  """

  # Post-task-3.2, `Valea.Mounts.list/1` is config truth over `icms:` ONLY —
  # a freshly scaffolded workspace carries no seeded mount, and every mount
  # is now EXTERNAL. `Valea.Workflows.list/0` (and thus `run_workflow`/
  # `distill_decisions`/`list_workflows`) only discovers `Workflows/*.md`
  # under `Valea.Mounts.enabled/1` — the legacy scaffold's physical (but
  # unregistered) `mounts/primary/` folder is invisible to it. So this suite
  # mounts a REAL external ICM (`AgentCase.mount_test_icm!/2`) carrying the
  # same rich seed content the legacy starter mount used to ship, and every
  # workflow path this suite exercises is that ICM's ABSOLUTE resolved path
  # (`icm.root`-relative), never the old `mounts/primary/...`
  # workspace-relative literal.
  setup do
    ws = AgentCase.open_workspace!("Primary")

    icm =
      AgentCase.mount_test_icm!(ws.path,
        name: "Primary",
        pages: %{
          "Workflows/New Inquiry Triage.md" => @new_inquiry_triage,
          "Workflows/Weekly Admin Review.md" => @weekly_admin_review
        }
      )

    %{"data" => %{"generation" => generation}} = rpc("get_workspace", %{})

    %{workspace: ws.path, parent: Path.dirname(ws.path), generation: generation, icm: icm}
  end

  defp wf_path(icm), do: Path.join(icm.root, "Workflows/New Inquiry Triage.md")
  defp disabled_wf_path(icm), do: Path.join(icm.root, "Workflows/Weekly Admin Review.md")

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

  describe "run_workflow" do
    test "happy path returns run_id and session_id and eventually queues a proposal", %{
      generation: generation,
      parent: parent,
      icm: icm
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

      assert %{"success" => true, "data" => %{"runId" => run_id, "sessionId" => session_id}} =
               rpc(
                 "run_workflow",
                 %{"path" => wf_path(icm), "input" => @input_path, "generation" => generation},
                 ["runId", "sessionId"]
               )

      assert is_binary(run_id)
      assert is_binary(session_id)

      pending_path = Path.join([parent, "Primary", "queue", "pending", run_id <> ".json"])
      wait_until(fn -> File.exists?(pending_path) end)
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation, icm: icm} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "run_workflow",
                 %{
                   "path" => wf_path(icm),
                   "input" => @input_path,
                   "generation" => generation - 1
                 },
                 ["runId", "sessionId"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end

    test "a disabled workflow surfaces workflow_disabled", %{generation: generation, icm: icm} do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "run_workflow",
                 %{
                   "path" => disabled_wf_path(icm),
                   "input" => @input_path,
                   "generation" => generation
                 },
                 ["runId", "sessionId"]
               )

      assert inspect(errors) =~ "workflow_disabled"
    end

    test "a missing input surfaces input_not_found", %{generation: generation, icm: icm} do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "run_workflow",
                 %{
                   "path" => wf_path(icm),
                   "input" => "sources/mail/normalized/does-not-exist.json",
                   "generation" => generation
                 },
                 ["runId", "sessionId"]
               )

      assert inspect(errors) =~ "input_not_found"
    end
  end

  describe "distill_decisions" do
    defp write_distill_workflow!(icm) do
      dir = Path.join(icm.root, "Workflows")
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

    defp write_decided_item!(parent, dir, run_id, decided_at, icm) do
      item = %{
        "schema" => "queue_item/v2",
        "run_id" => run_id,
        "workflow" => wf_path(icm),
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
      parent: parent,
      icm: icm
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))
      write_distill_workflow!(icm)

      recent = DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.to_iso8601()
      write_decided_item!(parent, "approved", "d1", recent, icm)

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
      generation: generation
    } do
      # This suite's own minimal mount seed (see module `setup`) only
      # carries "New Inquiry Triage.md" and "Weekly Admin Review.md" by
      # default -- no Distill Decisions contract exists anywhere in the
      # workspace unless a test writes one via `write_distill_workflow!/1`,
      # so this exercises the genuinely-missing-contract branch of
      # `distill_path/0` directly, no extra fixture teardown needed.
      assert %{"success" => false, "errors" => errors} =
               rpc("distill_decisions", %{"generation" => generation}, ["runId", "sessionId"])

      assert inspect(errors) =~ "workflow_not_found"
    end

    test "an empty decisions window surfaces no_recent_decisions", %{
      generation: generation,
      icm: icm
    } do
      write_distill_workflow!(icm)

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
    test "flattens the seeded workflow contracts", %{icm: icm} do
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

      assert triage = Enum.find(workflows, &(&1["path"] == wf_path(icm)))
      assert triage["name"] == "New Inquiry Triage"
      assert triage["enabled"] == true
      assert triage["triggerSource"] == "email.selected"
      assert triage["riskLevel"] == "medium"
      assert triage["sourceCount"] == 5
      assert is_list(triage["steps"])
      assert triage["steps"] != []
      # A-T15: mount provenance (the owning mount's manifest display name) —
      # this suite's `setup` mounts the seeded ICM as "Primary".
      assert triage["mount"] == "Primary"

      assert weekly = Enum.find(workflows, &(&1["path"] == disabled_wf_path(icm)))
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
