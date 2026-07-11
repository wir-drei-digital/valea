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

  @seed_message "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"

  # Hand-writes an imap-source message fixture and returns its workspace-relative
  # path (the seed rule keys on `source:` inside the leading frontmatter block).
  defp write_imap_message(workspace, suffix) do
    rel = "sources/mail/messages/imap-#{suffix}.md"
    abs = Path.join(workspace, rel)
    File.mkdir_p!(Path.dirname(abs))

    File.write!(abs, """
    ---
    id: imap-#{suffix}
    source: imap
    subject: "Live inquiry"
    ---
    A genuinely inbound message.
    """)

    rel
  end

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

    # Finishing the approval stamps the step-6 upgrade the crash skipped:
    # schema v2 + mailbox_ops (this legacy v1 file has no source_message ->
    # unreadable -> both ops skipped).
    landed = approved_path(workspace, id) |> File.read!() |> Jason.decode!()
    assert landed["schema"] == "queue_item/v2"
    assert landed["mailbox_ops"]["draft_append"]["status"] == "skipped"
    assert landed["mailbox_ops"]["archive_source"]["status"] == "skipped"

    {:ok, entries} = Valea.Audit.entries(50)
    entry = Enum.find(entries, &(&1["type"] == "item_approved" and &1["run_id"] == id))
    assert entry
    assert entry["recovered"] == true
  end

  test "recover/1 stamps pending mailbox_ops when finishing a crashed approve of an imap-source item, and broadcasts",
       %{workspace: workspace} do
    id = run_id("rec2v2")
    source = write_imap_message(workspace, "rec2v2")
    # A claimed v2 processing file whose draft was written (step 4 done) but
    # whose step-6 upgrade-rewrite never ran.
    write_pending(workspace, id, %{"schema" => "queue_item/v2", "source_message" => source})
    File.mkdir_p!(Path.dirname(processing_path(workspace, id)))
    File.rename!(pending_path(workspace, id), processing_path(workspace, id))

    draft_abs = draft_path(workspace, id)
    File.mkdir_p!(Path.dirname(draft_abs))
    File.write!(draft_abs, "already executed")

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail_ops")
    Queue.recover(workspace)

    landed = approved_path(workspace, id) |> File.read!() |> Jason.decode!()
    assert landed["schema"] == "queue_item/v2"
    assert landed["mailbox_ops"]["draft_append"]["status"] == "pending"
    assert landed["mailbox_ops"]["archive_source"]["status"] == "pending"
    assert_receive {:mailbox_ops_pending, ^id}
  end

  test "recover/1 returns a crashed reject (claimed + rewritten, no draft, no rejected file) to pending for re-decision",
       %{workspace: workspace} do
    id = run_id("rejcrx")
    source = write_imap_message(workspace, "rejcrx")
    write_pending(workspace, id, %{"source_message" => source})
    {:ok, %{item: item}} = Queue.get(id)

    # Simulate reject dying between its v2 rewrite and the final rename: the
    # claimed processing file already carries the archive_source-only ops.
    item2 =
      item
      |> Map.put("schema", "queue_item/v2")
      |> Map.put("mailbox_ops", %{"archive_source" => %{"status" => "pending"}})

    File.mkdir_p!(Path.dirname(processing_path(workspace, id)))
    File.write!(processing_path(workspace, id), Jason.encode!(item2))
    File.rm!(pending_path(workspace, id))

    Queue.recover(workspace)

    refute File.exists?(processing_path(workspace, id))
    refute File.exists?(rejected_path(workspace, id))
    assert File.exists?(pending_path(workspace, id))

    {:ok, entries} = Valea.Audit.entries(50)
    assert Enum.any?(entries, &(&1["type"] == "approval_recovered" and &1["run_id"] == id))

    # The re-pended item is fully decidable again — approving re-stamps BOTH ops.
    {:ok, %{revision: revision}} = Queue.get(id)
    assert {:ok, _} = Queue.approve(id, revision)
    landed = approved_path(workspace, id) |> File.read!() |> Jason.decode!()
    assert landed["mailbox_ops"]["draft_append"]["status"] == "pending"
    assert landed["mailbox_ops"]["archive_source"]["status"] == "pending"
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

  ## queue_item/v2 — durable mailbox-op intents

  test "approve/2 accepts a legacy v1 envelope (no source_message) end-to-end and upgrades it to v2 with skipped ops",
       %{workspace: workspace} do
    id = run_id("v1v1v1")
    # A hand-written legacy pending file: schema v1, no source_message key.
    write_pending(workspace, id, %{"schema" => "queue_item/v1"})
    {:ok, %{revision: revision}} = Queue.get(id)

    assert {:ok, _} = Queue.approve(id, revision)

    landed = approved_path(workspace, id) |> File.read!() |> Jason.decode!()
    assert landed["schema"] == "queue_item/v2"
    # source_message absent -> unreadable -> both ops skipped.
    assert landed["mailbox_ops"]["draft_append"]["status"] == "skipped"
    assert landed["mailbox_ops"]["archive_source"]["status"] == "skipped"
  end

  test "approve/2 on a seed-source item lands a v2 envelope with both ops skipped", %{
    workspace: workspace
  } do
    id = run_id("seed01")
    write_pending(workspace, id, %{"source_message" => @seed_message})
    {:ok, %{revision: revision}} = Queue.get(id)

    assert {:ok, _} = Queue.approve(id, revision)

    landed = approved_path(workspace, id) |> File.read!() |> Jason.decode!()
    assert landed["schema"] == "queue_item/v2"
    assert landed["mailbox_ops"]["draft_append"]["status"] == "skipped"
    assert landed["mailbox_ops"]["archive_source"]["status"] == "skipped"
  end

  test "approve/2 on an imap-source item lands a v2 envelope with both ops pending", %{
    workspace: workspace
  } do
    id = run_id("imap01")
    source = write_imap_message(workspace, "imap01")
    write_pending(workspace, id, %{"source_message" => source})
    {:ok, %{revision: revision}} = Queue.get(id)

    assert {:ok, _} = Queue.approve(id, revision)

    landed = approved_path(workspace, id) |> File.read!() |> Jason.decode!()
    assert landed["schema"] == "queue_item/v2"
    assert landed["mailbox_ops"]["draft_append"]["status"] == "pending"
    assert landed["mailbox_ops"]["archive_source"]["status"] == "pending"
  end

  test "approve/2 broadcasts {:mailbox_ops_pending, run_id} on the mail_ops topic", %{
    workspace: workspace
  } do
    id = run_id("bcast1")
    write_pending(workspace, id, %{"source_message" => @seed_message})
    {:ok, %{revision: revision}} = Queue.get(id)

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail_ops")
    assert {:ok, _} = Queue.approve(id, revision)
    assert_receive {:mailbox_ops_pending, ^id}
  end

  test "reject/2 writes only an archive_source intent, upgrades to v2, removes the pending file, broadcasts",
       %{workspace: workspace} do
    id = run_id("rej001")
    source = write_imap_message(workspace, "rej001")
    write_pending(workspace, id, %{"source_message" => source})
    {:ok, %{revision: revision}} = Queue.get(id)

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail_ops")
    assert {:ok, %{}} = Queue.reject(id, revision)
    assert_receive {:mailbox_ops_pending, ^id}

    refute File.exists?(pending_path(workspace, id))
    refute File.exists?(processing_path(workspace, id))
    landed = rejected_path(workspace, id) |> File.read!() |> Jason.decode!()
    assert landed["schema"] == "queue_item/v2"
    assert landed["mailbox_ops"]["archive_source"]["status"] == "pending"
    refute Map.has_key?(landed["mailbox_ops"], "draft_append")
  end

  test "rejecting twice: the second call is queue_item_gone (rename-is-the-claim)", %{
    workspace: workspace
  } do
    id = run_id("rej2x2")
    write_pending(workspace, id)
    {:ok, %{revision: revision}} = Queue.get(id)

    assert {:ok, %{}} = Queue.reject(id, revision)
    assert {:error, :queue_item_gone} = Queue.reject(id, revision)
    # And an approve after the reject is excluded the same way.
    assert {:error, :queue_item_gone} = Queue.approve(id, revision)
  end

  test "a source_message that traverses out of the workspace is treated as unreadable -> ops skipped",
       %{workspace: workspace} do
    # A readable imap-looking file OUTSIDE the workspace (two levels up, in
    # the isolated app dir) — it would seed "pending" ops if the traversal
    # were followed.
    outside = [workspace, "..", "..", "outside.md"] |> Path.join() |> Path.expand()
    File.write!(outside, "---\nsource: imap\n---\nBody.\n")

    id = run_id("escp01")
    write_pending(workspace, id, %{"source_message" => "../../outside.md"})
    {:ok, %{revision: revision}} = Queue.get(id)
    assert {:ok, _} = Queue.approve(id, revision)

    landed = approved_path(workspace, id) |> File.read!() |> Jason.decode!()
    assert landed["mailbox_ops"]["draft_append"]["status"] == "skipped"
    assert landed["mailbox_ops"]["archive_source"]["status"] == "skipped"
  end

  test "recover/1 resolves a LEGACY reject crash window (pending + rejected both present): rejected wins",
       %{workspace: workspace} do
    id = run_id("crash1")
    # The original reject flow wrote rejected/ first and removed pending/
    # second; a crash in between left both. The claim-based reject can no
    # longer produce this, but recover/1 still sweeps it defensively.
    write_pending(workspace, id)
    File.mkdir_p!(Path.dirname(rejected_path(workspace, id)))
    File.write!(rejected_path(workspace, id), File.read!(pending_path(workspace, id)))

    Queue.recover(workspace)

    refute File.exists?(pending_path(workspace, id))
    assert File.exists?(rejected_path(workspace, id))

    {:ok, entries} = Valea.Audit.entries(50)
    assert Enum.any?(entries, &(&1["type"] == "reject_recovered" and &1["run_id"] == id))
  end

  test "update_mailbox_op/3 rewrites an approved envelope's op in place and broadcasts", %{
    workspace: workspace
  } do
    id = run_id("upd001")
    source = write_imap_message(workspace, "upd001")
    write_pending(workspace, id, %{"source_message" => source})
    {:ok, %{revision: revision}} = Queue.get(id)
    assert {:ok, _} = Queue.approve(id, revision)

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail_ops")

    assert {:ok, updated} =
             Queue.update_mailbox_op(id, "archive_source", %{"status" => "done"})

    assert updated["mailbox_ops"]["archive_source"]["status"] == "done"
    assert_receive {:mailbox_ops_updated, ^id}

    on_disk = approved_path(workspace, id) |> File.read!() |> Jason.decode!()
    assert on_disk["mailbox_ops"]["archive_source"]["status"] == "done"
    # The untouched op is preserved.
    assert on_disk["mailbox_ops"]["draft_append"]["status"] == "pending"
  end

  test "update_mailbox_op/3 finds a rejected envelope too and can carry extra keys", %{
    workspace: workspace
  } do
    id = run_id("upd002")
    source = write_imap_message(workspace, "upd002")
    write_pending(workspace, id, %{"source_message" => source})
    {:ok, %{revision: revision}} = Queue.get(id)
    assert {:ok, %{}} = Queue.reject(id, revision)

    assert {:ok, _} =
             Queue.update_mailbox_op(id, "archive_source", %{
               "status" => "error",
               "error" => "imap timeout"
             })

    on_disk = rejected_path(workspace, id) |> File.read!() |> Jason.decode!()
    assert on_disk["mailbox_ops"]["archive_source"]["status"] == "error"
    assert on_disk["mailbox_ops"]["archive_source"]["error"] == "imap timeout"
  end

  test "update_mailbox_op/3 on an unknown run_id -> queue_item_gone" do
    assert {:error, :queue_item_gone} = Queue.update_mailbox_op("nope", "archive_source", %{})
  end

  ## list_decided/0 + get_decided/1

  test "list_decided/0 returns approved + rejected items newest-first with the decided shape", %{
    workspace: workspace
  } do
    approved_id = run_id("dec001")
    rejected_id = run_id("dec002")

    write_pending(workspace, approved_id, %{"source_message" => @seed_message})
    {:ok, %{revision: rev_a}} = Queue.get(approved_id)
    assert {:ok, _} = Queue.approve(approved_id, rev_a)

    write_pending(workspace, rejected_id, %{"source_message" => @seed_message})
    {:ok, %{revision: rev_r}} = Queue.get(rejected_id)
    assert {:ok, _} = Queue.reject(rejected_id, rev_r)

    assert {:ok, [first, second]} = Queue.list_decided()
    # rejected_id sorts lexically after approved_id -> newest first.
    assert first.run_id == rejected_id
    assert first.decided == "rejected"
    assert second.run_id == approved_id
    assert second.decided == "approved"

    assert second.title == "Reply to Priya"
    assert second.kind == "email_draft"
    assert is_map(second.mailbox_ops)
    assert is_binary(second.created_at)
  end

  test "get_decided/1 returns the raw envelope and which dir it lives in", %{workspace: workspace} do
    id = run_id("dec003")
    write_pending(workspace, id, %{"source_message" => @seed_message})
    {:ok, %{revision: revision}} = Queue.get(id)
    assert {:ok, _} = Queue.approve(id, revision)

    assert {:ok, %{item: item, decided: "approved"}} = Queue.get_decided(id)
    assert item["run_id"] == id
    assert item["schema"] == "queue_item/v2"
  end

  test "get_decided/1 on an undecided run_id -> queue_item_gone", %{workspace: workspace} do
    id = run_id("dec004")
    write_pending(workspace, id)
    assert {:error, :queue_item_gone} = Queue.get_decided(id)
  end
end
