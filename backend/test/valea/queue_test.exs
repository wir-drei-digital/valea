defmodule Valea.QueueTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Queue

  setup do
    ws = AgentCase.open_workspace!()
    %{workspace: ws.path}
  end

  ## helpers

  defp write_pending(workspace, run_id, overrides \\ %{}) do
    envelope = envelope(run_id, overrides)
    path = Path.join([workspace, "queue", "pending", run_id <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(envelope))
    envelope
  end

  defp envelope(run_id, overrides) do
    %{
      "schema" => "queue_item/v1",
      "run_id" => run_id,
      "session_id" => "sess-1",
      "workflow" => "icm/Workflows/New Inquiry Triage.md",
      "workflow_hash" => String.duplicate("a", 64),
      "input" => "sources/mail/messages/2026-07-09-priya-nair-seed0001.md",
      "input_hash" => String.duplicate("b", 64),
      "risk_level" => "medium",
      "approval" => "required",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{
        "schema" => "proposal/v1",
        "kind" => "email_draft",
        "title" => "Reply to Priya",
        "summary" => "Draft a warm reply to Priya's inquiry",
        "reasoning" => "Priya asked a straightforward pricing question",
        "sources" => ["icm/Clients/Priya Nair.md", "icm/Offers/Starter.md"],
        "proposed_action" => %{
          "type" => "create_email_draft",
          "to" => "priya@example.com",
          "subject" => "Re: Inquiry",
          "body_markdown" => "Hello Priya,\n\nThanks for reaching out!\n"
        }
      }
    }
    |> Map.merge(overrides)
  end

  defp pending_path(workspace, run_id),
    do: Path.join([workspace, "queue", "pending", run_id <> ".json"])

  defp processing_path(workspace, run_id),
    do: Path.join([workspace, "queue", "processing", run_id <> ".json"])

  defp approved_path(workspace, run_id),
    do: Path.join([workspace, "queue", "approved", run_id <> ".json"])

  defp rejected_path(workspace, run_id),
    do: Path.join([workspace, "queue", "rejected", run_id <> ".json"])

  defp draft_path(workspace, run_id),
    do: Path.join([workspace, "sources", "mail", "drafts", run_id <> ".md"])

  defp run_id(suffix), do: "20260710T000000Z-#{suffix}"

  ## list/0 + get/1

  test "list/0 returns pending items newest-first with the summary shape", %{workspace: workspace} do
    older = run_id("aaaaaa")
    newer = run_id("bbbbbb")
    write_pending(workspace, older)
    write_pending(workspace, newer)

    assert {:ok, [first, second]} = Queue.list()
    assert first.run_id == newer
    assert second.run_id == older

    assert first.title == "Reply to Priya"
    assert first.summary == "Draft a warm reply to Priya's inquiry"
    assert first.kind == "email_draft"
    assert first.risk_level == "medium"
    assert first.workflow == "icm/Workflows/New Inquiry Triage.md"
    assert first.valid == true
    assert is_binary(first.created_at)
  end

  test "get/1 returns the full envelope plus a stable revision", %{workspace: workspace} do
    id = run_id("cccccc")
    write_pending(workspace, id)

    assert {:ok, %{item: item, revision: revision}} = Queue.get(id)
    assert item["run_id"] == id
    assert item["schema"] == "queue_item/v1"
    assert is_binary(revision) and byte_size(revision) == 64

    assert {:ok, %{revision: ^revision}} = Queue.get(id)
  end

  test "get/1 on a missing run_id -> queue_item_gone" do
    assert {:error, :queue_item_gone} = Queue.get("does-not-exist")
  end

  ## invalid items

  test "list/0 and get/1 handle invalid pending JSON without crashing", %{workspace: workspace} do
    id = run_id("dddddd")
    File.write!(pending_path(workspace, id), "not json {{{")

    assert {:ok, [item]} = Queue.list()
    assert item.run_id == id
    assert item.valid == false
    assert is_binary(item.error)

    assert {:error, :queue_item_invalid} = Queue.get(id)
  end

  test "list/0 flags a well-formed JSON file that fails the envelope shape check", %{
    workspace: workspace
  } do
    id = run_id("eeeeee")
    write_pending(workspace, id, %{"schema" => "not_queue_item"})

    assert {:ok, [item]} = Queue.list()
    assert item.valid == false
    assert item.error == "invalid_schema"

    assert {:error, :queue_item_invalid} = Queue.get(id)
  end

  test "get/1 and approve/2 reject a subject with a control char (frontmatter injection)", %{
    workspace: workspace
  } do
    id = run_id("999999")

    injected =
      id
      |> envelope(%{})
      |> put_in(["payload", "proposed_action", "subject"], "Re: hi\nto: attacker@evil.test")

    bytes = Jason.encode!(injected)
    path = pending_path(workspace, id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    revision = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    assert {:error, :queue_item_invalid} = Queue.get(id)
    # Correct revision, so the invalidity (not a stale-hash) is what rejects it.
    assert {:error, :queue_item_invalid} = Queue.approve(id, revision)

    # Never claimed or executed: still pending, no processing/, no draft.
    assert File.exists?(path)
    refute File.exists?(processing_path(workspace, id))
    refute File.exists?(draft_path(workspace, id))
  end

  ## approve/2 happy path + audit ordering

  test "approve/2 happy path: writes the draft, moves pending -> approved, audits in order",
       %{workspace: workspace} do
    id = run_id("ffffff")
    write_pending(workspace, id)
    {:ok, %{revision: revision}} = Queue.get(id)

    assert {:ok, %{draft_path: draft_rel}} = Queue.approve(id, revision)
    assert draft_rel == "sources/mail/drafts/#{id}.md"

    draft_abs = Path.join(workspace, draft_rel)
    assert File.exists?(draft_abs)
    content = File.read!(draft_abs)

    assert content == """
           ---
           to: priya@example.com
           subject: Re: Inquiry
           run_id: #{id}
           workflow: icm/Workflows/New Inquiry Triage.md
           sources:
             - icm/Clients/Priya Nair.md
             - icm/Offers/Starter.md
           ---

           Hello Priya,

           Thanks for reaching out!
           """

    refute File.exists?(pending_path(workspace, id))
    refute File.exists?(processing_path(workspace, id))
    assert File.exists?(approved_path(workspace, id))

    {:ok, entries} = Valea.Audit.entries(100)

    chain =
      entries
      |> Enum.reverse()
      |> Enum.filter(&(&1["run_id"] == id))
      |> Enum.map(& &1["type"])

    assert chain == ["approval_intent", "action_executed", "item_approved"]
  end

  test "approve/2 with a stale revision -> queue_item_changed, file untouched", %{
    workspace: workspace
  } do
    id = run_id("111111")
    write_pending(workspace, id)

    assert {:error, :queue_item_changed} = Queue.approve(id, "0000000000000000")
    assert File.exists?(pending_path(workspace, id))
    refute File.exists?(processing_path(workspace, id))

    {:ok, entries} = Valea.Audit.entries(50)
    refute Enum.any?(entries, &(&1["run_id"] == id))
  end

  test "approving twice: the second call is queue_item_gone", %{workspace: workspace} do
    id = run_id("222222")
    write_pending(workspace, id)
    {:ok, %{revision: revision}} = Queue.get(id)

    assert {:ok, _} = Queue.approve(id, revision)
    assert {:error, :queue_item_gone} = Queue.approve(id, revision)
  end

  test "approve/2 is idempotent when the draft already exists (crash-recovery replay)", %{
    workspace: workspace
  } do
    id = run_id("333333")
    write_pending(workspace, id)

    draft_abs = draft_path(workspace, id)
    File.mkdir_p!(Path.dirname(draft_abs))
    File.write!(draft_abs, "PRE-EXISTING, MUST NOT BE OVERWRITTEN")

    {:ok, %{revision: revision}} = Queue.get(id)
    assert {:ok, %{draft_path: _}} = Queue.approve(id, revision)

    assert File.read!(draft_abs) == "PRE-EXISTING, MUST NOT BE OVERWRITTEN"
    assert File.exists?(approved_path(workspace, id))
  end

  ## reject/2

  test "reject/2 moves pending -> rejected and audits item_rejected", %{workspace: workspace} do
    id = run_id("444444")
    write_pending(workspace, id)
    {:ok, %{revision: revision}} = Queue.get(id)

    assert {:ok, %{}} = Queue.reject(id, revision)
    refute File.exists?(pending_path(workspace, id))
    assert File.exists?(rejected_path(workspace, id))

    {:ok, entries} = Valea.Audit.entries(50)
    assert Enum.any?(entries, &(&1["type"] == "item_rejected" and &1["run_id"] == id))
  end

  test "reject/2 with a stale revision -> queue_item_changed, file untouched", %{
    workspace: workspace
  } do
    id = run_id("555555")
    write_pending(workspace, id)

    assert {:error, :queue_item_changed} = Queue.reject(id, "0000000000000000")
    assert File.exists?(pending_path(workspace, id))
  end

  ## recover/1

  test "recover/1 completes a processing item whose draft already exists", %{
    workspace: workspace
  } do
    id = run_id("666666")
    write_pending(workspace, id)
    File.mkdir_p!(Path.dirname(processing_path(workspace, id)))
    File.rename!(pending_path(workspace, id), processing_path(workspace, id))

    draft_abs = draft_path(workspace, id)
    File.mkdir_p!(Path.dirname(draft_abs))
    File.write!(draft_abs, "already executed")

    Queue.recover(workspace)

    refute File.exists?(processing_path(workspace, id))
    assert File.exists?(approved_path(workspace, id))

    {:ok, entries} = Valea.Audit.entries(50)
    entry = Enum.find(entries, &(&1["type"] == "item_approved" and &1["run_id"] == id))
    assert entry
    assert entry["recovered"] == true
  end

  test "recover/1 returns an unfinished processing item (no draft) to pending", %{
    workspace: workspace
  } do
    id = run_id("777777")
    write_pending(workspace, id)
    File.mkdir_p!(Path.dirname(processing_path(workspace, id)))
    File.rename!(pending_path(workspace, id), processing_path(workspace, id))

    Queue.recover(workspace)

    refute File.exists?(processing_path(workspace, id))
    assert File.exists?(pending_path(workspace, id))

    {:ok, entries} = Valea.Audit.entries(50)
    assert Enum.any?(entries, &(&1["type"] == "approval_recovered" and &1["run_id"] == id))
  end

  test "recover/1 is a no-op when processing/ is empty", %{workspace: workspace} do
    assert Queue.recover(workspace) == :ok
  end

  ## run_id containment

  test "get/approve/reject reject a run_id that is not a safe basename" do
    assert {:error, :queue_item_gone} = Queue.get("../../etc/passwd")
    assert {:error, :queue_item_gone} = Queue.approve("../../etc/passwd", "whatever")
    assert {:error, :queue_item_gone} = Queue.reject("some/nested/path", "whatever")
  end
end
