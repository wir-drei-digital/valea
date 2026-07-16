defmodule Valea.Workflows.RunnerTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Workflows.Runner

  @input_path "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"
  @triage_relative_path "Workflows/New Inquiry Triage.md"
  @weekly_relative_path "Workflows/Weekly Admin Review.md"

  # `New Inquiry Triage.md`/`Weekly Admin Review.md`/`Current Pricing.md`
  # verbatim from the old starter mount's rich seed content (preserved at
  # `test/fixtures/starter_icm/`) — this whole suite exercises the Runner
  # against these three pages. `Valea.Mounts.list/1` is config truth over
  # `icms:` ONLY (no filesystem-glob discovery of an embedded
  # `mounts/<name>`), so `setup` mounts a REAL EXTERNAL ICM (via
  # `AgentCase.mount_test_icm!/2`) carrying this same content. Every mount
  # is external now, so every workflow/target path in this file is the
  # ICM's ABSOLUTE resolved path (`icm.root`-relative), never the old
  # `mounts/primary/...` workspace-relative literal — see
  # `Valea.Workflows`'s `workflow_path/2` and
  # `Valea.Workflows.MemoryProposal.check_target/2`, both of which only
  # accept that vocabulary for an external mount now.
  @new_inquiry_triage """
  ---
  enabled: true
  trigger: { type: manual, source: email.selected }
  sources:
    - { id: current_email, type: email, required: true }
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

  @current_pricing """
  # Current Pricing

  - Founder Coaching Package: CHF 2,400 for 6 sessions (75 min, every two weeks)
  - Discovery call: free, 30 minutes
  - Workshop (half-day): CHF 1,900 flat

  Avoid leading with price unless explicitly asked.
  """

  setup do
    ws = AgentCase.open_workspace!("Primary")

    icm =
      AgentCase.mount_test_icm!(ws.path,
        name: "Primary",
        pages: %{
          "Workflows/New Inquiry Triage.md" => @new_inquiry_triage,
          "Workflows/Weekly Admin Review.md" => @weekly_admin_review,
          "Pricing/Current Pricing.md" => @current_pricing
        }
      )

    %{workspace: ws.path, icm: icm}
  end

  defp wf_path(icm), do: Path.join(icm.root, @triage_relative_path)
  defp pricing_path(icm), do: Path.join(icm.root, "Pricing/Current Pricing.md")

  defp generation, do: Valea.Workspace.Manager.generation()

  defp ws_input(path), do: %{"kind" => "workspace", "path" => path}
  defp icm_input(icm_id, path), do: %{"kind" => "icm", "icm_id" => icm_id, "path" => path}

  test "run/4 on a disabled workflow -> workflow_disabled", %{icm: icm} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:error, :workflow_disabled} =
             Runner.run(icm.mount_key, @weekly_relative_path, ws_input(@input_path), generation())
  end

  test "run/4 on missing input -> input_unavailable", %{icm: icm} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:error, :input_unavailable} =
             Runner.run(
               icm.mount_key,
               @triage_relative_path,
               ws_input("sources/mail/normalized/does-not-exist.json"),
               generation()
             )
  end

  test "run/4 on an unknown workflow relative_path -> not_found", %{icm: icm} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:error, :not_found} =
             Runner.run(
               icm.mount_key,
               "Workflows/Nonexistent.md",
               ws_input(@input_path),
               generation()
             )
  end

  test "run/4 with an unknown mount_key -> not_found", %{} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:error, :not_found} =
             Runner.run(
               "no-such-mount",
               @triage_relative_path,
               ws_input(@input_path),
               generation()
             )
  end

  test "run/4 with an input_locator that traverses out of the workspace -> input_unavailable",
       %{icm: icm} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:error, :input_unavailable} =
             Runner.run(
               icm.mount_key,
               @triage_relative_path,
               ws_input("../../../../../../../../etc/passwd"),
               generation()
             )
  end

  test "run/4 with a relative_path that lexically starts with the mount's Workflows/ but traverses out of it -> not_found",
       %{icm: icm} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))
    File.mkdir_p!(Path.join(icm.root, "Offers"))
    File.write!(Path.join(icm.root, "Offers/escaped.md"), "# Escaped\n")

    assert {:error, :not_found} =
             Runner.run(
               icm.mount_key,
               "Workflows/../Offers/escaped.md",
               ws_input(@input_path),
               generation()
             )
  end

  test "run/4 when the harness is unavailable: workflow_run_started audit is paired with a start_failed workflow_run_finished audit",
       %{icm: icm} do
    Valea.App.Config.set_harness_command(["no-such-binary-zzz"])

    assert {:error, :harness_unavailable} =
             Runner.run(icm.mount_key, @triage_relative_path, ws_input(@input_path), generation())

    {:ok, entries} = Valea.Audit.entries(20)
    chain = entries |> Enum.reverse() |> Enum.map(& &1["type"])

    assert Enum.take(chain, -2) == ["workflow_run_started", "workflow_run_finished"]

    started = Enum.find(entries, &(&1["type"] == "workflow_run_started"))
    finished = Enum.find(entries, &(&1["type"] == "workflow_run_finished"))

    assert started["run_id"] == finished["run_id"]
    assert finished["outcome"] == "start_failed"
  end

  # Task 7.2's core TDD scenario (spec §"Related ICMs" / brief Step 1): an
  # `input_locator` whose ICM is not mounted must fail preflight with
  # `:input_unavailable` BEFORE any subprocess spawns — no run id
  # generated, no staging dir created, no `workflow_run_started` audited.
  test "an input_locator whose ICM is unmounted -> input_unavailable before any subprocess spawns",
       %{workspace: workspace, icm: icm} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    other =
      AgentCase.mount_test_icm!(workspace,
        name: "Other",
        pages: %{"Notes/Doc.md" => "# Doc\n"}
      )

    locator = icm_input(other.id, "Notes/Doc.md")
    {:ok, _} = Valea.Mounts.unmount(workspace, other.mount_key)

    {:ok, before_entries} = Valea.Audit.entries(200)
    started_before = Enum.count(before_entries, &(&1["type"] == "workflow_run_started"))

    assert {:error, :input_unavailable} =
             Runner.run(icm.mount_key, @triage_relative_path, locator, generation())

    {:ok, after_entries} = Valea.Audit.entries(200)
    started_after = Enum.count(after_entries, &(&1["type"] == "workflow_run_started"))

    assert started_after == started_before

    assert Path.join([workspace, "queue", "staging", "*"]) |> Path.wildcard() == []
  end

  test "run.json sidecar carries icm_id, mount_key, and icm_root (Task 7.3 dependency)", %{
    workspace: workspace,
    icm: icm
  } do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    # `Runner.run/4` only returns after `start_run/6` has synchronously
    # written the sidecar (before starting the session) — see the
    # `run_generated/3`-describe comment below for the same "read
    # immediately, no wait_until needed" reasoning.
    assert {:ok, %{run_id: run_id}} =
             Runner.run(icm.mount_key, @triage_relative_path, ws_input(@input_path), generation())

    sidecar_path = Path.join([workspace, "queue", "staging", run_id, "run.json"])
    sidecar = sidecar_path |> File.read!() |> Jason.decode!()

    assert sidecar["icm_id"] == icm.id
    assert sidecar["mount_key"] == icm.mount_key
    assert sidecar["icm_root"] == icm.root
  end

  describe "run_generated/4" do
    test "writes the generated input to staging before the session starts, and carries it through sidecar/envelope/audit",
         %{workspace: workspace, icm: icm} do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

      digest = "# Recent decisions (last 30 days)\n\nsome content\n"

      assert {:ok, %{run_id: run_id, session_id: session_id}} =
               Runner.run_generated(
                 icm.mount_key,
                 @triage_relative_path,
                 "input-decisions.md",
                 digest
               )

      expected_rel = Path.join(["queue", "staging", run_id, "input-decisions.md"])
      input_abs = Path.join(workspace, expected_rel)

      # `run_generated/4` only returns once `Valea.Agents.start_session/1`
      # has, which is strictly after `start_run/6` materializes the
      # generated input to staging — so the file is already there,
      # BEFORE the fake harness's `workflow_happy` scenario ever receives
      # its first `session/prompt`.
      assert File.read!(input_abs) == digest

      sidecar_path = Path.join([workspace, "queue", "staging", run_id, "run.json"])
      sidecar = sidecar_path |> File.read!() |> Jason.decode!()
      assert sidecar["input"] == expected_rel
      assert is_binary(sidecar["input_hash"]) and byte_size(sidecar["input_hash"]) == 64
      assert sidecar["icm_id"] == icm.id
      assert sidecar["mount_key"] == icm.mount_key
      assert sidecar["icm_root"] == icm.root

      pending_path = Path.join([workspace, "queue", "pending", run_id <> ".json"])
      wait_until(fn -> File.exists?(pending_path) end)

      item = pending_path |> File.read!() |> Jason.decode!()
      assert item["input"] == expected_rel
      assert item["session_id"] == session_id
      assert item["source_message"] == expected_rel
      assert is_binary(item["input_hash"]) and byte_size(item["input_hash"]) == 64

      {:ok, entries} = Valea.Audit.entries(50)

      started =
        Enum.find(entries, &(&1["type"] == "workflow_run_started" and &1["run_id"] == run_id))

      assert started["input"] == expected_rel
    end

    test "a traversal-shaped input_name is contained to the staging dir (Path.basename defense-in-depth)",
         %{workspace: workspace, icm: icm} do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

      assert {:ok, %{run_id: run_id}} =
               Runner.run_generated(
                 icm.mount_key,
                 @triage_relative_path,
                 "../../../../etc/passwd",
                 "digest bytes"
               )

      # Basenamed to "passwd" and written INSIDE this run's own staging dir —
      # never escaping it (and never touching the real /etc/passwd, which
      # this process has no write access to regardless).
      expected_rel = Path.join(["queue", "staging", run_id, "passwd"])
      assert File.read!(Path.join(workspace, expected_rel)) == "digest bytes"

      sidecar_path = Path.join([workspace, "queue", "staging", run_id, "run.json"])
      sidecar = sidecar_path |> File.read!() |> Jason.decode!()
      assert sidecar["input"] == expected_rel
    end

    test "grants read of the generated input's absolute path (Task 7.2 fix — was ungranted since Task 5.5)",
         %{workspace: workspace, icm: icm} do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

      assert {:ok, %{run_id: run_id, session_id: session_id}} =
               Runner.run_generated(
                 icm.mount_key,
                 @triage_relative_path,
                 "input-decisions.md",
                 "digest bytes"
               )

      on_exit(fn -> AgentCase.kill_session(session_id) end)

      input_abs =
        Path.join([workspace, "queue", "staging", run_id, "input-decisions.md"])

      pid = GenServer.whereis({:via, Registry, {Valea.Agents.SessionRegistry, session_id}})
      policy_ctx = :sys.get_state(pid).policy_ctx

      assert input_abs in policy_ctx.read_roots
    end
  end

  test "run/4 accepts a workflow whose relative_path resolves inside an enabled EXTERNAL mount root (A2-T5b)",
       %{workspace: workspace} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    ext =
      AgentCase.mount_test_icm!(workspace,
        name: "Ext",
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        pages: %{
          "Workflows/External Triage.md" => """
          ---
          enabled: true
          risk_level: medium
          approval:
            required: true
          ---
          # External Triage

          ## Process

          1. Do the thing.
          """
        }
      )

    ext_wf_path = Path.join(ext.root, "Workflows/External Triage.md")

    assert {:ok, %{run_id: run_id}} =
             Runner.run(
               ext.mount_key,
               "Workflows/External Triage.md",
               ws_input(@input_path),
               generation()
             )

    pending_path = Path.join([workspace, "queue", "pending", run_id <> ".json"])
    wait_until(fn -> File.exists?(pending_path) end)

    item = pending_path |> File.read!() |> Jason.decode!()
    # `workflow` carries the ABSOLUTE physical path verbatim — the run
    # input/queue-envelope/audit vocabulary for external content is the
    # resolved absolute path, not a workspace-relative one (binding
    # semantic 4).
    assert item["workflow"] == ext_wf_path
    assert item["payload"]["kind"] == "email_draft"
  end

  test "happy path: pending queue item created, staging removed, audit chain", %{
    workspace: workspace,
    icm: icm
  } do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:ok, %{run_id: run_id, session_id: session_id}} =
             Runner.run(icm.mount_key, @triage_relative_path, ws_input(@input_path), generation())

    assert is_binary(run_id)
    assert is_binary(session_id)

    pending_path = Path.join([workspace, "queue", "pending", run_id <> ".json"])
    wait_until(fn -> File.exists?(pending_path) end)

    item = pending_path |> File.read!() |> Jason.decode!()
    assert item["schema"] == "queue_item/v2"
    assert item["run_id"] == run_id
    assert item["session_id"] == session_id
    assert item["workflow"] == wf_path(icm)
    assert is_binary(item["workflow_hash"]) and byte_size(item["workflow_hash"]) == 64
    assert item["input"] == @input_path
    assert item["source_message"] == @input_path
    assert is_binary(item["input_hash"]) and byte_size(item["input_hash"]) == 64
    assert item["risk_level"] == "medium"
    assert item["payload"]["kind"] == "email_draft"
    assert item["payload"]["schema"] == "proposal/v1"

    staging_dir = Path.join([workspace, "queue", "staging", run_id])
    refute File.dir?(staging_dir)

    {:ok, entries} = Valea.Audit.entries(100)

    chain =
      entries
      |> Enum.reverse()
      |> Enum.filter(&(&1["run_id"] == run_id))
      |> Enum.map(& &1["type"])

    assert chain == ["workflow_run_started", "queue_item_created", "workflow_run_finished"]

    finished =
      entries
      |> Enum.find(&(&1["type"] == "workflow_run_finished" and &1["run_id"] == run_id))

    assert finished["outcome"] == "proposal_created"
  end

  test "finalize/2 with no staging file: outcome no_proposal, no pending item", %{
    workspace: workspace
  } do
    run_id = "20260710T000000Z-000000"

    Runner.finalize(run_id, workspace)

    {:ok, entries} = Valea.Audit.entries(20)
    entry = Enum.find(entries, &(&1["run_id"] == run_id))
    assert entry["type"] == "workflow_run_finished"
    assert entry["outcome"] == "no_proposal"

    refute File.exists?(Path.join([workspace, "queue", "pending", run_id <> ".json"]))
  end

  test "finalize/2 with an invalid payload: outcome invalid_proposal, staging kept", %{
    workspace: workspace,
    icm: icm
  } do
    run_id = "20260710T000000Z-111111"
    staging_dir = Path.join([workspace, "queue", "staging", run_id])
    File.mkdir_p!(staging_dir)

    invalid_payload = %{
      "schema" => "proposal/v1",
      "kind" => "email_draft",
      "title" => "Reply to inquiry",
      "summary" => "A summary.",
      "reasoning" => "Because.",
      "sources" => [],
      "proposed_action" => %{
        "type" => "create_email_draft",
        # "to" is missing — invalid per proposal/v1
        "subject" => "Re: hi",
        "body_markdown" => "Body."
      }
    }

    proposal_path = Path.join(staging_dir, "proposal.json")
    File.write!(proposal_path, Jason.encode!(invalid_payload))

    File.write!(
      Path.join(staging_dir, "run.json"),
      Jason.encode!(%{
        "run_id" => run_id,
        "session_id" => "sess-1",
        "workflow" => wf_path(icm),
        "workflow_hash" => "deadbeef",
        "input" => @input_path,
        "input_hash" => "cafebabe",
        "risk_level" => "medium",
        "approval" => %{"required" => true},
        "created_at" => DateTime.to_iso8601(DateTime.utc_now())
      })
    )

    Runner.finalize(run_id, workspace)

    {:ok, entries} = Valea.Audit.entries(20)
    entry = Enum.find(entries, &(&1["run_id"] == run_id))
    assert entry["type"] == "workflow_run_finished"
    assert entry["outcome"] == "invalid_proposal"

    assert File.exists?(proposal_path)
    refute File.exists?(Path.join([workspace, "queue", "pending", run_id <> ".json"]))
  end

  test "finalize/2 rejects a proposal whose subject carries a control char: invalid_proposal", %{
    workspace: workspace,
    icm: icm
  } do
    run_id = "20260710T000000Z-222222"
    staging_dir = Path.join([workspace, "queue", "staging", run_id])
    File.mkdir_p!(staging_dir)

    injected_payload = %{
      "schema" => "proposal/v1",
      "kind" => "email_draft",
      "title" => "Reply to inquiry",
      "summary" => "A summary.",
      "reasoning" => "Because.",
      "sources" => [],
      "proposed_action" => %{
        "type" => "create_email_draft",
        "to" => "priya@example.com",
        # Newline would inject a second frontmatter key at draft time.
        "subject" => "Re: hi\nto: attacker@evil.test",
        "body_markdown" => "Body."
      }
    }

    File.write!(Path.join(staging_dir, "proposal.json"), Jason.encode!(injected_payload))

    File.write!(
      Path.join(staging_dir, "run.json"),
      Jason.encode!(%{
        "run_id" => run_id,
        "session_id" => "sess-1",
        "workflow" => wf_path(icm),
        "workflow_hash" => "deadbeef",
        "input" => @input_path,
        "input_hash" => "cafebabe",
        "risk_level" => "medium",
        "approval" => %{"required" => true},
        "created_at" => DateTime.to_iso8601(DateTime.utc_now())
      })
    )

    Runner.finalize(run_id, workspace)

    {:ok, entries} = Valea.Audit.entries(20)
    entry = Enum.find(entries, &(&1["run_id"] == run_id))
    assert entry["type"] == "workflow_run_finished"
    assert entry["outcome"] == "invalid_proposal"

    refute File.exists?(Path.join([workspace, "queue", "pending", run_id <> ".json"]))
  end

  test "finalize/2 called twice: second call does not duplicate the pending item", %{
    workspace: workspace,
    icm: icm
  } do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:ok, %{run_id: run_id}} =
             Runner.run(icm.mount_key, @triage_relative_path, ws_input(@input_path), generation())

    pending_path = Path.join([workspace, "queue", "pending", run_id <> ".json"])
    wait_until(fn -> File.exists?(pending_path) end)
    first_bytes = File.read!(pending_path)

    # Staging is already gone at this point, so a second finalize must be a
    # pure no-op with respect to the pending item — it must NOT be rewritten.
    Runner.finalize(run_id, workspace)

    assert File.read!(pending_path) == first_bytes
  end

  test "a workflow session that dies before any turn ends still reaches a terminus (no_proposal), staging cleaned",
       %{workspace: workspace, icm: icm} do
    # crash_mid_turn emits a chunk then halts the adapter WITHOUT ending the
    # turn, so {:turn} never fires. The session's death path must still fire
    # on_turn_end("died") → finalize → no_proposal, or the run would orphan.
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("crash_mid_turn"))

    assert {:ok, %{run_id: run_id}} =
             Runner.run(icm.mount_key, @triage_relative_path, ws_input(@input_path), generation())

    wait_until(fn ->
      {:ok, entries} = Valea.Audit.entries(50)

      Enum.any?(
        entries,
        &(&1["type"] == "workflow_run_finished" and &1["run_id"] == run_id)
      )
    end)

    {:ok, entries} = Valea.Audit.entries(50)

    finished =
      Enum.filter(
        entries,
        &(&1["type"] == "workflow_run_finished" and &1["run_id"] == run_id)
      )

    # Exactly one terminus (not double-fired by both {:turn} and the exit).
    assert [%{"outcome" => "no_proposal"}] = finished

    # No orphaned staging.
    refute File.dir?(Path.join([workspace, "queue", "staging", run_id]))
  end

  test "recover_staging/1 gives orphaned staging dirs a terminus and clears them", %{
    workspace: workspace,
    icm: icm
  } do
    # (a) pre-turn orphan: run.json only, no proposal was ever written.
    orphan = "20260710T000000Z-aaaaaa"
    orphan_dir = Path.join([workspace, "queue", "staging", orphan])
    File.mkdir_p!(orphan_dir)
    File.write!(Path.join(orphan_dir, "run.json"), Jason.encode!(sidecar(orphan, icm)))

    # (b) proposal written but finalize never ran (hard crash after the write).
    salvage = "20260710T000000Z-bbbbbb"
    salvage_dir = Path.join([workspace, "queue", "staging", salvage])
    File.mkdir_p!(salvage_dir)
    File.write!(Path.join(salvage_dir, "run.json"), Jason.encode!(sidecar(salvage, icm)))
    File.write!(Path.join(salvage_dir, "proposal.json"), Jason.encode!(valid_proposal()))

    Runner.recover_staging(workspace)

    {:ok, entries} = Valea.Audit.entries(100)

    orphan_fin =
      Enum.find(entries, &(&1["type"] == "workflow_run_finished" and &1["run_id"] == orphan))

    assert orphan_fin["outcome"] == "no_proposal"
    refute File.dir?(orphan_dir)

    salvage_fin =
      Enum.find(entries, &(&1["type"] == "workflow_run_finished" and &1["run_id"] == salvage))

    assert salvage_fin["outcome"] == "proposal_created"
    assert File.exists?(Path.join([workspace, "queue", "pending", salvage <> ".json"]))
    refute File.dir?(salvage_dir)
  end

  describe "memory proposal pairs" do
    test "two valid pairs become two pending items with server-owned fields", %{
      workspace: ws,
      icm: icm
    } do
      staging = seed_run!(ws, "r-mem-1", icm)
      target = pricing_path(icm)

      base = :crypto.hash(:sha256, File.read!(target)) |> Base.encode16(case: :lower)

      # Task 7.3: `target_path` is the agent's OWN ICM-relative path (the
      # agent's session `cwd` IS `icm.root`, post-7.2) — never the old
      # absolute `icm.root`-joined literal.
      File.write!(
        Path.join(staging, "proposals/a-pricing.json"),
        Jason.encode!(%{
          "schema" => "memory_update/v1",
          "target_path" => "Pricing/Current Pricing.md",
          "base_sha256" => base,
          "reason" => "rate changed",
          "sources" => [target]
        })
      )

      File.write!(Path.join(staging, "proposals/a-pricing.md"), "# Pricing\n\n150 EUR\n")

      File.write!(
        Path.join(staging, "proposals/b-wf.json"),
        Jason.encode!(%{
          "schema" => "memory_update/v1",
          "target_path" => @triage_relative_path,
          "base_sha256" => nil,
          "reason" => "tighten steps",
          "sources" => []
        })
      )

      File.write!(Path.join(staging, "proposals/b-wf.md"), "# WF\n")

      :ok = Runner.finalize("r-mem-1", ws)

      p1 = Path.join(ws, "queue/pending/r-mem-1-m1.json") |> File.read!() |> Jason.decode!()
      p2 = Path.join(ws, "queue/pending/r-mem-1-m2.json") |> File.read!() |> Jason.decode!()

      assert p1["run_id"] == "r-mem-1-m1"
      assert p1["risk_level"] == "medium"
      assert p1["payload"]["kind"] == "memory_update"
      assert p1["payload"]["summary"] == "rate changed"
      assert p1["payload"]["proposed_action"]["type"] == "apply_page_content"

      assert p1["payload"]["proposed_action"]["target"]["locator"] == %{
               "kind" => "icm",
               "icm_id" => icm.id,
               "path" => "Pricing/Current Pricing.md"
             }

      assert p1["payload"]["proposed_action"]["target"]["content_markdown"] ==
               "# Pricing\n\n150 EUR\n"

      refute Map.has_key?(p1, "source_message")

      # Task 7.5: `RiskTier.classify/1` tiers the ICM locator directly (its
      # `path` — ICM-relative by construction — against `@behavior_files`
      # and the `Workflows/` prefix), so a `Workflows/…` target is "high"
      # again even under cwd == the ICM root.
      assert p2["risk_level"] == "high"
      assert p2["payload"]["title"] == "New page: New Inquiry Triage.md"

      assert p2["payload"]["proposed_action"]["target"]["locator"] == %{
               "kind" => "icm",
               "icm_id" => icm.id,
               "path" => @triage_relative_path
             }

      refute File.exists?(Path.join(ws, "queue/staging/r-mem-1"))
    end

    # Task 7.5's own TDD requirement, spelled out at the finalize_pair
    # boundary: a memory-update proposal targeting the ICM's own
    # `AGENTS.md` — a behavior-bearing file, not under `Workflows/` —
    # must get `risk_level: "high"` end to end, not "medium".
    test "a memory-update pair targeting AGENTS.md gets risk_level high", %{
      workspace: ws,
      icm: icm
    } do
      staging = seed_run!(ws, "r-mem-agents", icm)

      File.write!(
        Path.join(staging, "proposals/a-agents.json"),
        Jason.encode!(%{
          "schema" => "memory_update/v1",
          "target_path" => "AGENTS.md",
          "base_sha256" => nil,
          "reason" => "tighten instructions",
          "sources" => []
        })
      )

      File.write!(Path.join(staging, "proposals/a-agents.md"), "# Agents\n")

      :ok = Runner.finalize("r-mem-agents", ws)

      item =
        Path.join(ws, "queue/pending/r-mem-agents-m1.json") |> File.read!() |> Jason.decode!()

      assert item["risk_level"] == "high"

      assert item["payload"]["proposed_action"]["target"]["locator"] == %{
               "kind" => "icm",
               "icm_id" => icm.id,
               "path" => "AGENTS.md"
             }
    end

    test "invalid pair audits memory_proposal_invalid and keeps staging", %{
      workspace: ws,
      icm: icm
    } do
      staging = seed_run!(ws, "r-mem-2", icm)

      File.write!(
        Path.join(staging, "proposals/bad.json"),
        Jason.encode!(%{
          "schema" => "memory_update/v1",
          # Escapes the sidecar's icm_root via `..` —
          # `MemoryProposal.check_icm_target/2` rejects it with
          # `:outside_mount` regardless of what exists at the far end (same
          # containment posture every other chokepoint in this codebase
          # applies). A bare filename like "AGENTS.md" would no longer be
          # invalid post-7.3 — it is now a perfectly valid ICM-relative
          # target (`icm.root <> "/AGENTS.md"`), unlike the old
          # `check_target/2`'s workspace-scan attribution this fixture used
          # to exercise.
          "target_path" => "../../etc/passwd",
          "base_sha256" => nil,
          "reason" => "x",
          "sources" => []
        })
      )

      File.write!(Path.join(staging, "proposals/bad.md"), "x")

      :ok = Runner.finalize("r-mem-2", ws)

      assert Path.join(ws, "queue/pending") |> Path.join("r-mem-2*") |> Path.wildcard() == []
      assert File.exists?(Path.join(ws, "queue/staging/r-mem-2"))

      {:ok, entries} = Valea.Audit.entries(50)

      assert Enum.any?(
               entries,
               &(&1["type"] == "memory_proposal_invalid" and &1["file"] == "bad.json")
             )
    end

    # The brief sketches this via "the fake adapter records opts"; the fake
    # adapter (test/support/fake_adapter.exs) does not record session opts.
    # The existing, established seam for observing a live session's
    # policy_ctx is `:sys.get_state/1` on the SessionServer pid looked up via
    # the Registry — the exact pattern `session_read_roots_test.exs` already
    # uses for this same struct. `policy_ctx` is fixed at `init/1` time and
    # never mutated afterward, so reading it right after `run/4` returns
    # (which only returns once `init/1` — and thus policy_ctx construction —
    # has completed) is race-free regardless of how fast the fake harness's
    # async finalize runs.
    test "run/4 grants: proposals dir writable, run.json not, exact input read, cwd is the owning ICM (Task 7.2)",
         %{
           workspace: workspace,
           icm: icm
         } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

      {:ok, expected_input_abs} =
        Valea.Icm.Locator.resolve(workspace, ws_input(@input_path))

      assert {:ok, %{run_id: run_id, session_id: session_id}} =
               Runner.run(
                 icm.mount_key,
                 @triage_relative_path,
                 ws_input(@input_path),
                 generation()
               )

      on_exit(fn -> AgentCase.kill_session(session_id) end)

      pid = GenServer.whereis({:via, Registry, {Valea.Agents.SessionRegistry, session_id}})
      policy_ctx = :sys.get_state(pid).policy_ctx

      staging_dir = Path.join([workspace, "queue", "staging", run_id])

      assert policy_ctx.cwd == icm.root
      assert policy_ctx.write_paths == [Path.join(staging_dir, "proposal.json")]
      assert policy_ctx.write_roots == [Path.join(staging_dir, "proposals")]

      # Task 7.2: the ONE exact input read grant, folded into read_roots
      # alongside the primary ICM's own root — nothing else (no related
      # ICMs declared in this fixture, so `additional_roots` is exactly
      # `[input_abs]`).
      assert policy_ctx.read_roots == [icm.root, expected_input_abs]

      # Regression assertion (brief Step 1): a generic chat session in the
      # SAME ICM gets no such grant — it cannot read this exact input.
      {:ok, %{id: chat_session_id}} =
        AgentCase.start_session(workspace, "happy", %{mount_key: icm.mount_key})

      on_exit(fn -> AgentCase.kill_session(chat_session_id) end)

      chat_pid =
        GenServer.whereis({:via, Registry, {Valea.Agents.SessionRegistry, chat_session_id}})

      chat_ctx = :sys.get_state(chat_pid).policy_ctx

      refute expected_input_abs in chat_ctx.read_roots

      read_item = %{
        "kind" => "read",
        "toolName" => "Read",
        "rawInput" => %{"file_path" => expected_input_abs}
      }

      assert Valea.Agents.PermissionPolicy.decide(read_item, chat_ctx) == :ask
    end
  end

  describe "finalize/2 idempotent re-finalize (B5 part 2)" do
    # Mirrors the B3-review scenario: a valid primary proposal (creates
    # <run_id>.json) alongside one invalid memory pair — the invalid pair
    # keeps staging in place for inspection, which is exactly the condition
    # `recover_staging/1` re-finalizes at boot.
    defp seed_mixed_run!(ws, run_id, icm) do
      staging = seed_run!(ws, run_id, icm)

      File.write!(Path.join(staging, "proposal.json"), Jason.encode!(valid_proposal()))

      File.write!(
        Path.join(staging, "proposals/bad.json"),
        Jason.encode!(%{
          "schema" => "memory_update/v1",
          # Escapes icm_root — see the identical comment in "invalid pair
          # audits memory_proposal_invalid and keeps staging" above.
          "target_path" => "../../etc/passwd",
          "base_sha256" => nil,
          "reason" => "x",
          "sources" => []
        })
      )

      File.write!(Path.join(staging, "proposals/bad.md"), "x")

      staging
    end

    test "re-finalizing a staging dir whose items were already created creates no new pending files and does not re-audit queue_item_created",
         %{workspace: ws, icm: icm} do
      run_id = "r-idem-1"
      seed_mixed_run!(ws, run_id, icm)

      :ok = Runner.finalize(run_id, ws)

      pending_path = Path.join(ws, "queue/pending/#{run_id}.json")
      assert File.exists?(pending_path)
      assert File.exists?(Path.join(ws, "queue/staging/#{run_id}"))
      first_bytes = File.read!(pending_path)

      # Re-finalize (simulating recover_staging's boot-time re-run over a
      # staging dir kept for inspection because of the sibling invalid pair).
      :ok = Runner.finalize(run_id, ws)

      assert File.read!(pending_path) == first_bytes

      assert Path.join(ws, "queue/pending") |> Path.join("#{run_id}*") |> Path.wildcard() == [
               pending_path
             ]

      {:ok, entries} = Valea.Audit.entries(100)

      created_count =
        Enum.count(entries, &(&1["type"] == "queue_item_created" and &1["run_id"] == run_id))

      assert created_count == 1

      finished =
        entries
        |> Enum.reverse()
        |> Enum.filter(&(&1["type"] == "workflow_run_finished" and &1["run_id"] == run_id))
        |> Enum.map(& &1["outcome"])

      # First call: the primary item was created, which outranks the sibling
      # invalid pair for outcome. Second call: nothing new is created (the
      # primary id is skipped) but the pair is STILL invalid — honestly
      # re-audited — so this call's outcome is invalid_proposal.
      assert finished == ["proposal_created", "invalid_proposal"]
    end

    test "an already-decided item is not resurrected by re-finalize", %{workspace: ws, icm: icm} do
      run_id = "r-idem-2"
      seed_mixed_run!(ws, run_id, icm)

      :ok = Runner.finalize(run_id, ws)

      pending_path = Path.join(ws, "queue/pending/#{run_id}.json")
      assert File.exists?(pending_path)

      # Simulate a human decision moving the item out of pending/ (hand-move
      # to avoid depending on Queue.approve's own guards here).
      approved_dir = Path.join(ws, "queue/approved")
      File.mkdir_p!(approved_dir)
      approved_path = Path.join(approved_dir, "#{run_id}.json")
      File.rename!(pending_path, approved_path)

      :ok = Runner.finalize(run_id, ws)

      refute File.exists?(pending_path)
      assert File.exists?(approved_path)
    end
  end

  # Mirrors the file's existing sidecar/staging setup (`sidecar/2` below,
  # `start_run/6`'s own `run.json` shape) so `finalize/2` can be driven
  # directly against hand-seeded staging, same as every other finalize test
  # in this file.
  defp seed_run!(ws, run_id, icm) do
    staging = Path.join(ws, "queue/staging/#{run_id}")
    File.mkdir_p!(Path.join(staging, "proposals"))

    run = %{
      "run_id" => run_id,
      "session_id" => "s1",
      "workflow" => wf_path(icm),
      "workflow_hash" => String.duplicate("a", 64),
      "input" => @input_path,
      "input_hash" => String.duplicate("b", 64),
      "risk_level" => "medium",
      "approval" => %{"required" => true},
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      # Task 7.2's real sidecar shape (verified by this file's own "run.json
      # sidecar carries icm_id, mount_key, and icm_root" test) — Task 7.3's
      # `MemoryProposal.check_icm_target/2` reads `icm_id`/`icm_root`
      # straight off this map, so a hand-seeded sidecar without them would
      # make every memory pair below `:icm_unavailable` regardless of its
      # own `target_path`.
      "icm_id" => icm.id,
      "mount_key" => icm.mount_key,
      "icm_root" => icm.root
    }

    File.write!(Path.join(staging, "run.json"), Jason.encode!(run))
    staging
  end

  defp sidecar(run_id, icm) do
    %{
      "run_id" => run_id,
      "session_id" => "sess-1",
      "workflow" => wf_path(icm),
      "workflow_hash" => "deadbeef",
      "input" => @input_path,
      "input_hash" => "cafebabe",
      "risk_level" => "medium",
      "approval" => %{"required" => true},
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "icm_id" => icm.id,
      "mount_key" => icm.mount_key,
      "icm_root" => icm.root
    }
  end

  defp valid_proposal do
    %{
      "schema" => "proposal/v1",
      "kind" => "email_draft",
      "title" => "Reply",
      "summary" => "A summary.",
      "reasoning" => "Because.",
      "sources" => [],
      "proposed_action" => %{
        "type" => "create_email_draft",
        "to" => "a@b.test",
        "subject" => "Re: hi",
        "body_markdown" => "Body."
      }
    }
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
