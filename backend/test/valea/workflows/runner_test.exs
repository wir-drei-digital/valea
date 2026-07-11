defmodule Valea.Workflows.RunnerTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Workflows.Runner

  @wf_path "icm/Workflows/New Inquiry Triage.md"
  @disabled_wf_path "icm/Workflows/Weekly Admin Review.md"
  @input_path "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"

  setup do
    ws = AgentCase.open_workspace!()
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
    assert {:error, :not_found} = Runner.run("icm/Workflows/Nonexistent.md", @input_path)
  end

  test "run/2 with an input_path that traverses out of the workspace -> input_not_found" do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:error, :input_not_found} =
             Runner.run(@wf_path, "../../../../../../../../etc/passwd")
  end

  test "run/2 with a workflow_path that lexically starts with icm/Workflows/ but traverses out of it -> not_found",
       %{workspace: workspace} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))
    File.write!(Path.join(workspace, "icm/Offers/escaped.md"), "# Escaped\n")

    assert {:error, :not_found} =
             Runner.run("icm/Workflows/../Offers/escaped.md", @input_path)
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
