defmodule Valea.Workflows.RunnerTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Workflows.Runner

  @wf_path "mounts/primary/Workflows/New Inquiry Triage.md"
  @disabled_wf_path "mounts/primary/Workflows/Weekly Admin Review.md"
  @input_path "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"

  # A fresh scaffold (T8) mints its own real mount from the template's rich
  # seed content (New Inquiry Triage, Weekly Admin Review, ...) at
  # `mounts/<slug-of-name>` — naming the workspace "Primary" lands it at
  # exactly `mounts/primary`, the path this whole suite exercises the
  # Runner against.
  setup do
    ws = AgentCase.open_workspace!("Primary")
    %{workspace: ws.path}
  end

  test "run/2 on a disabled workflow -> workflow_disabled" do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))
    assert {:error, :workflow_disabled} = Runner.run(@disabled_wf_path, @input_path)
  end

  test "run/2 on missing input -> input_not_found" do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:error, :input_not_found} =
             Runner.run(@wf_path, "sources/mail/normalized/does-not-exist.json")
  end

  test "run/2 on an unknown workflow path -> not_found" do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:error, :not_found} =
             Runner.run("mounts/primary/Workflows/Nonexistent.md", @input_path)
  end

  test "run/2 with an input_path that traverses out of the workspace -> input_not_found" do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:error, :input_not_found} =
             Runner.run(@wf_path, "../../../../../../../../etc/passwd")
  end

  test "run/2 with a workflow_path that lexically starts with mounts/primary/Workflows/ but traverses out of it -> not_found",
       %{workspace: workspace} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))
    File.write!(Path.join(workspace, "mounts/primary/Offers/escaped.md"), "# Escaped\n")

    assert {:error, :not_found} =
             Runner.run("mounts/primary/Workflows/../Offers/escaped.md", @input_path)
  end

  test "run/2 when the harness is unavailable: workflow_run_started audit is paired with a start_failed workflow_run_finished audit" do
    Valea.App.Config.set_harness_command(["no-such-binary-zzz"])

    assert {:error, :harness_unavailable} = Runner.run(@wf_path, @input_path)

    {:ok, entries} = Valea.Audit.entries(20)
    chain = entries |> Enum.reverse() |> Enum.map(& &1["type"])

    assert Enum.take(chain, -2) == ["workflow_run_started", "workflow_run_finished"]

    started = Enum.find(entries, &(&1["type"] == "workflow_run_started"))
    finished = Enum.find(entries, &(&1["type"] == "workflow_run_finished"))

    assert started["run_id"] == finished["run_id"]
    assert finished["outcome"] == "start_failed"
  end

  test "happy path: pending queue item created, staging removed, audit chain", %{
    workspace: workspace
  } do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:ok, %{run_id: run_id, session_id: session_id}} = Runner.run(@wf_path, @input_path)
    assert is_binary(run_id)
    assert is_binary(session_id)

    pending_path = Path.join([workspace, "queue", "pending", run_id <> ".json"])
    wait_until(fn -> File.exists?(pending_path) end)

    item = pending_path |> File.read!() |> Jason.decode!()
    assert item["schema"] == "queue_item/v2"
    assert item["run_id"] == run_id
    assert item["session_id"] == session_id
    assert item["workflow"] == @wf_path
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

  test "run/2 accepts a workflow whose path resolves inside an enabled EXTERNAL mount root (A2-T5b)",
       %{workspace: workspace} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    ext =
      Path.join(
        System.tmp_dir!(),
        "valea-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(ext, "Workflows"))
    on_exit(fn -> File.rm_rf!(ext) end)
    Manifest.write!(ext, %{id: "ext-id", name: "Ext", description: ""})

    File.write!(
      Path.join(ext, "Workflows/External Triage.md"),
      """
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
    )

    config_path = Path.join(workspace, "config/workspace.yaml")
    {:ok, doc} = YamlElixir.read_from_file(config_path)

    File.write!(
      config_path,
      "version: #{doc["version"]}\nid: #{inspect(doc["id"])}\nmounts:\n  ext:\n    kind: \"path\"\n    ref: #{inspect(ext)}\n"
    )

    [ext_mount] = Enum.filter(Mounts.enabled(workspace), &(&1.name == "ext"))
    ext_wf_path = Path.join(ext_mount.root, "Workflows/External Triage.md")

    assert {:ok, %{run_id: run_id}} = Runner.run(ext_wf_path, @input_path)

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
    workspace: workspace
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
        "workflow" => @wf_path,
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
    workspace: workspace
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
        "workflow" => @wf_path,
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
    workspace: workspace
  } do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))
    assert {:ok, %{run_id: run_id}} = Runner.run(@wf_path, @input_path)

    pending_path = Path.join([workspace, "queue", "pending", run_id <> ".json"])
    wait_until(fn -> File.exists?(pending_path) end)
    first_bytes = File.read!(pending_path)

    # Staging is already gone at this point, so a second finalize must be a
    # pure no-op with respect to the pending item — it must NOT be rewritten.
    Runner.finalize(run_id, workspace)

    assert File.read!(pending_path) == first_bytes
  end

  test "a workflow session that dies before any turn ends still reaches a terminus (no_proposal), staging cleaned",
       %{workspace: workspace} do
    # crash_mid_turn emits a chunk then halts the adapter WITHOUT ending the
    # turn, so {:turn} never fires. The session's death path must still fire
    # on_turn_end("died") → finalize → no_proposal, or the run would orphan.
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("crash_mid_turn"))

    assert {:ok, %{run_id: run_id}} = Runner.run(@wf_path, @input_path)

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
    workspace: workspace
  } do
    # (a) pre-turn orphan: run.json only, no proposal was ever written.
    orphan = "20260710T000000Z-aaaaaa"
    orphan_dir = Path.join([workspace, "queue", "staging", orphan])
    File.mkdir_p!(orphan_dir)
    File.write!(Path.join(orphan_dir, "run.json"), Jason.encode!(sidecar(orphan)))

    # (b) proposal written but finalize never ran (hard crash after the write).
    salvage = "20260710T000000Z-bbbbbb"
    salvage_dir = Path.join([workspace, "queue", "staging", salvage])
    File.mkdir_p!(salvage_dir)
    File.write!(Path.join(salvage_dir, "run.json"), Jason.encode!(sidecar(salvage)))
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
    test "two valid pairs become two pending items with server-owned fields", %{workspace: ws} do
      staging = seed_run!(ws, "r-mem-1")
      target = "mounts/primary/Pricing/Current Pricing.md"

      base =
        :crypto.hash(:sha256, File.read!(Path.join(ws, target))) |> Base.encode16(case: :lower)

      File.write!(
        Path.join(staging, "proposals/a-pricing.json"),
        Jason.encode!(%{
          "schema" => "memory_update/v1",
          "target_path" => target,
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
          "target_path" => "mounts/primary/Workflows/New Inquiry Triage.md",
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
      assert p1["payload"]["proposed_action"]["content_markdown"] == "# Pricing\n\n150 EUR\n"
      refute Map.has_key?(p1, "source_message")

      # server-derived tier overrides anything claimed: workflow target is high
      assert p2["risk_level"] == "high"
      assert p2["payload"]["title"] == "New page: New Inquiry Triage.md"

      refute File.exists?(Path.join(ws, "queue/staging/r-mem-1"))
    end

    test "invalid pair audits memory_proposal_invalid and keeps staging", %{workspace: ws} do
      staging = seed_run!(ws, "r-mem-2")

      File.write!(
        Path.join(staging, "proposals/bad.json"),
        Jason.encode!(%{
          "schema" => "memory_update/v1",
          "target_path" => "AGENTS.md",
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
    # never mutated afterward, so reading it right after `run/2` returns
    # (which only returns once `init/1` — and thus policy_ctx construction —
    # has completed) is race-free regardless of how fast the fake harness's
    # async finalize runs.
    test "run/2 grants: proposals dir writable, run.json not, staging readable", %{
      workspace: workspace
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

      assert {:ok, %{run_id: run_id, session_id: session_id}} = Runner.run(@wf_path, @input_path)
      on_exit(fn -> AgentCase.kill_session(session_id) end)

      pid = GenServer.whereis({:via, Registry, {Valea.Agents.SessionRegistry, session_id}})
      policy_ctx = :sys.get_state(pid).policy_ctx

      staging_dir = Path.join([workspace, "queue", "staging", run_id])

      assert policy_ctx.write_paths == [Path.join(staging_dir, "proposal.json")]
      assert policy_ctx.write_roots == [Path.join(staging_dir, "proposals")]
      assert Path.join(["queue", "staging", run_id]) in policy_ctx.read_roots
    end
  end

  # Mirrors the file's existing sidecar/staging setup (`sidecar/1` below,
  # `start_run/6`'s own `run.json` shape) so `finalize/2` can be driven
  # directly against hand-seeded staging, same as every other finalize test
  # in this file.
  defp seed_run!(ws, run_id) do
    staging = Path.join(ws, "queue/staging/#{run_id}")
    File.mkdir_p!(Path.join(staging, "proposals"))

    run = %{
      "run_id" => run_id,
      "session_id" => "s1",
      "workflow" => @wf_path,
      "workflow_hash" => String.duplicate("a", 64),
      "input" => @input_path,
      "input_hash" => String.duplicate("b", 64),
      "risk_level" => "medium",
      "approval" => %{"required" => true},
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(Path.join(staging, "run.json"), Jason.encode!(run))
    staging
  end

  defp sidecar(run_id) do
    %{
      "run_id" => run_id,
      "session_id" => "sess-1",
      "workflow" => @wf_path,
      "workflow_hash" => "deadbeef",
      "input" => @input_path,
      "input_hash" => "cafebabe",
      "risk_level" => "medium",
      "approval" => %{"required" => true},
      "created_at" => DateTime.to_iso8601(DateTime.utc_now())
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
