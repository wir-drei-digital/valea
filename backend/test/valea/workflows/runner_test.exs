defmodule Valea.Workflows.RunnerTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Workflows.Runner

  @wf_path "icm/Workflows/New Inquiry Triage.md"
  @disabled_wf_path "icm/Workflows/Weekly Admin Review.md"
  @input_path "sources/mail/normalized/priya-nair-inquiry.json"

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
    assert item["schema"] == "queue_item/v1"
    assert item["run_id"] == run_id
    assert item["session_id"] == session_id
    assert item["workflow"] == @wf_path
    assert is_binary(item["workflow_hash"]) and byte_size(item["workflow_hash"]) == 64
    assert item["input"] == @input_path
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
