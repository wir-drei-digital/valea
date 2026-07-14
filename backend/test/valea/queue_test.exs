defmodule Valea.QueueTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Queue

  setup do
    # Named "Primary" (not the bare default) so the mount slug is "primary" —
    # the apply_page_content tests below target mounts/primary/... paths and
    # need Valea.Mounts.set_enabled("primary", ...) to resolve. None of the
    # existing tests in this file reference the mount slug, so this is safe
    # for them.
    ws = AgentCase.open_workspace!("Primary")
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

  # Mounts a real EXTERNAL ICM carrying a `Pricing/Current Pricing.md` seed
  # page — the target the `apply_page_content` tests below read/write.
  # Post-task-3.2, `Valea.Mounts.list/1` no longer discovers the legacy
  # scaffold's embedded `mounts/primary/` folder (config truth, `icms:`
  # only), and `MemoryProposal.check_target/2`'s `Mounts.mount_for/2`
  # can only attribute a page to a REGISTERED, external (absolute-rooted)
  # mount — so any test that actually EXECUTES an `apply_page_content`
  # (as opposed to merely rejecting/hashing against a file that happens to
  # exist on disk) needs one of these, and its `target_path` must be the
  # mounted ICM's absolute path, never the old `"mounts/primary/..."`
  # workspace-relative literal.
  defp mount_primary!(workspace, pages \\ %{}) do
    default_pages = %{"Pricing/Current Pricing.md" => "# Current Pricing\n\nCHF 100\n"}
    AgentCase.mount_test_icm!(workspace, name: "Primary", pages: Map.merge(default_pages, pages))
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
  # path. Carries both `source: imap` and a `uid` — the two frontmatter facts
  # the op-seeding rule keys on for both draft_append and archive_source.
  defp write_imap_message(workspace, suffix, opts \\ []) do
    rel = "sources/mail/messages/imap-#{suffix}.md"
    abs = Path.join(workspace, rel)
    File.mkdir_p!(Path.dirname(abs))

    uid_line = if Keyword.get(opts, :uid, true), do: "uid: 4242\n", else: ""

    File.write!(abs, """
    ---
    id: imap-#{suffix}
    source: imap
    #{uid_line}subject: "Live inquiry"
    ---
    A genuinely inbound message.
    """)

    rel
  end

  # A readable source whose frontmatter is NOT `source: imap` — e.g. a non-mail
  # ICM workflow that emitted a kind:"email_draft". Must seed all ops "skipped".
  defp write_icm_source(workspace, suffix) do
    rel = "sources/icm/#{suffix}.md"
    abs = Path.join(workspace, rel)
    File.mkdir_p!(Path.dirname(abs))

    File.write!(abs, """
    ---
    id: icm-#{suffix}
    source: icm
    subject: "Follow-up"
    ---
    A non-mail source.
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

  test "approve/2 on a non-mail (ICM) source email_draft lands both ops skipped", %{
    workspace: workspace
  } do
    # A non-mail workflow that emitted a kind:"email_draft" — its source file
    # is readable but NOT source: imap. The old rule ("any readable non-seed ->
    # pending") would APPEND a To-less draft to the real Drafts folder and park
    # archive_source in :source_has_no_uid forever; both must be skipped.
    id = run_id("icm001")
    source = write_icm_source(workspace, "icm001")
    write_pending(workspace, id, %{"source_message" => source})
    {:ok, %{revision: revision}} = Queue.get(id)

    assert {:ok, _} = Queue.approve(id, revision)

    landed = approved_path(workspace, id) |> File.read!() |> Jason.decode!()
    assert landed["mailbox_ops"]["draft_append"]["status"] == "skipped"
    assert landed["mailbox_ops"]["archive_source"]["status"] == "skipped"
  end

  test "approve/2 on an imap source with no uid: draft_append pending, archive_source skipped", %{
    workspace: workspace
  } do
    # A genuine mail source can still draft a reply, but with no uid there is
    # nothing to move — archive_source is unsatisfiable, so it is skipped
    # rather than left permanently failing.
    id = run_id("nouid1")
    source = write_imap_message(workspace, "nouid1", uid: false)
    write_pending(workspace, id, %{"source_message" => source})
    {:ok, %{revision: revision}} = Queue.get(id)

    assert {:ok, _} = Queue.approve(id, revision)

    landed = approved_path(workspace, id) |> File.read!() |> Jason.decode!()
    assert landed["mailbox_ops"]["draft_append"]["status"] == "pending"
    assert landed["mailbox_ops"]["archive_source"]["status"] == "skipped"
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

  test "list_decided/0 carries mount_key/path/icm_name for memory items and nil for email items",
       %{
         workspace: workspace
       } do
    # Email item (no target locator in proposed_action)
    email_id = run_id("dec_email")
    write_pending(workspace, email_id, %{"source_message" => @seed_message})
    {:ok, %{revision: email_rev}} = Queue.get(email_id)
    assert {:ok, _} = Queue.approve(email_id, email_rev)

    # Memory item with a target locator — a create target (base_sha256
    # nil, page absent), so approval succeeds on the first try.
    memory_id = run_id("dec_memory")
    icm = mount_primary!(workspace)

    memory_envelope = %{
      "schema" => "queue_item/v2",
      "run_id" => memory_id,
      "workflow" => Path.join(icm.root, "Workflows/Test.md"),
      "risk_level" => "low",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{
        "title" => "Update test",
        "summary" => "Test update",
        "kind" => "memory_update",
        "sources" => [],
        "proposed_action" => %{
          "type" => "apply_page_content",
          "target" => %{
            "locator" => Valea.Icm.Locator.icm(icm.id, "Notes/Test.md"),
            "base_sha256" => nil,
            "content_markdown" => "# Test"
          }
        }
      }
    }

    path = Path.join([workspace, "queue", "pending", memory_id <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(memory_envelope))
    {:ok, %{revision: memory_rev}} = Queue.get(memory_id)
    assert {:ok, _} = Queue.approve(memory_id, memory_rev)

    assert {:ok, items} = Queue.list_decided()
    email_item = Enum.find(items, &(&1.run_id == email_id))
    memory_item = Enum.find(items, &(&1.run_id == memory_id))

    assert email_item != nil
    assert is_nil(email_item.mount_key)
    assert is_nil(email_item.path)
    assert is_nil(email_item.icm_name)

    assert memory_item != nil
    assert memory_item.mount_key == icm.mount_key
    assert memory_item.path == "Notes/Test.md"
    assert memory_item.icm_name == "Primary"
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

  ## apply_page_content — memory_update execute arm (B4, re-keyed onto ICM
  ## locators by Task 7.3)

  # `target` is now a `Valea.Icm.Locator` map (never a raw path) — Task
  # 7.3's `proposed_action.target = %{locator, base_sha256,
  # content_markdown}`, replacing the old flat `target_path` sibling.
  defp pending_memory!(ws, run_id, locator, base, content) do
    item = %{
      "schema" => "queue_item/v2",
      "run_id" => run_id,
      "workflow" => "mounts/primary/Workflows/New Inquiry Triage.md",
      "risk_level" => "medium",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{
        "title" => "Update x",
        "summary" => "why",
        "kind" => "memory_update",
        "sources" => [],
        "proposed_action" => %{
          "type" => "apply_page_content",
          "target" => %{
            "locator" => locator,
            "base_sha256" => base,
            "content_markdown" => content
          }
        }
      }
    }

    dir = Path.join(ws, "queue/pending")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, run_id <> ".json"), Jason.encode!(item))
    item
  end

  describe "apply_page_content" do
    test "approve applies an edit when the base hash matches", %{workspace: ws} do
      icm = mount_primary!(ws)
      target = Path.join(icm.root, "Pricing/Current Pricing.md")
      old = File.read!(target)
      base = :crypto.hash(:sha256, old) |> Base.encode16(case: :lower)
      loc = Valea.Icm.Locator.icm(icm.id, "Pricing/Current Pricing.md")
      pending_memory!(ws, "m1", loc, base, "# Pricing\n\n150\n")

      {:ok, %{item: _, revision: rev}} = Queue.get("m1")
      assert {:ok, %{applied_path: ^target, draft_path: nil}} = Queue.approve("m1", rev)
      assert File.read!(target) == "# Pricing\n\n150\n"
      assert File.exists?(Path.join(ws, "queue/approved/m1.json"))

      approved = Path.join(ws, "queue/approved/m1.json") |> File.read!() |> Jason.decode!()
      assert approved["decided_at"]
      refute Map.has_key?(approved, "mailbox_ops")
    end

    test "approve creates a page when base is null and target absent", %{workspace: ws} do
      icm = mount_primary!(ws)
      target = Path.join(icm.root, "Decisions/2026-07.md")
      loc = Valea.Icm.Locator.icm(icm.id, "Decisions/2026-07.md")
      pending_memory!(ws, "m2", loc, nil, "# Decisions\n")
      {:ok, %{revision: rev}} = Queue.get("m2")
      assert {:ok, %{applied_path: ^target}} = Queue.approve("m2", rev)
      assert File.read!(target) == "# Decisions\n"
    end

    test "approve success path audits in order and stamps a locator + resolved_path on action_executed (Task 7.4)",
         %{
           workspace: ws
         } do
      icm = mount_primary!(ws)
      target = Path.join(icm.root, "Pricing/Current Pricing.md")
      old = File.read!(target)
      base = :crypto.hash(:sha256, old) |> Base.encode16(case: :lower)
      loc = Valea.Icm.Locator.icm(icm.id, "Pricing/Current Pricing.md")
      pending_memory!(ws, "m1o", loc, base, "# Pricing\n\n200\n")

      {:ok, %{revision: rev}} = Queue.get("m1o")
      assert {:ok, %{applied_path: ^target}} = Queue.approve("m1o", rev)

      {:ok, entries} = Valea.Audit.entries(100)

      chain =
        entries
        |> Enum.reverse()
        |> Enum.filter(&(&1["run_id"] == "m1o"))

      assert Enum.map(chain, & &1["type"]) == [
               "approval_intent",
               "action_executed",
               "item_approved"
             ]

      action_executed = Enum.find(chain, &(&1["type"] == "action_executed"))
      assert action_executed["target"]["locator"]["icm_id"] == icm.id
      assert action_executed["target"]["locator"]["path"] == "Pricing/Current Pricing.md"
      assert action_executed["target"]["resolved_path"] == target
    end

    test "hash mismatch: nothing written, item back in pending, apply_conflict audited (carrying locator + resolved_path)",
         %{
           workspace: ws
         } do
      icm = mount_primary!(ws)
      target = Path.join(icm.root, "Pricing/Current Pricing.md")
      old = File.read!(target)
      loc = Valea.Icm.Locator.icm(icm.id, "Pricing/Current Pricing.md")
      pending_memory!(ws, "m3", loc, String.duplicate("0", 64), "# clobber\n")
      {:ok, %{revision: rev}} = Queue.get("m3")

      assert {:error, :apply_conflict} = Queue.approve("m3", rev)
      assert File.read!(target) == old
      assert File.exists?(Path.join(ws, "queue/pending/m3.json"))
      refute File.exists?(Path.join(ws, "queue/processing/m3.json"))

      {:ok, entries} = Valea.Audit.entries(20)
      conflict = Enum.find(entries, &(&1["type"] == "apply_conflict" and &1["run_id"] == "m3"))
      assert conflict
      assert conflict["target"]["locator"]["icm_id"] == icm.id
      # Resolution itself succeeded (the ICM is mounted and healthy) — only
      # the hash guard rejected it — so the resolved physical path still
      # rides along for forensic reconstruction (Task 7.4).
      assert conflict["target"]["resolved_path"] == target
      assert conflict["reason"] == "page_changed"
    end

    test "create-target-exists and disabled-mount are conflicts too", %{workspace: ws} do
      icm = mount_primary!(ws)
      target = Path.join(icm.root, "Pricing/Current Pricing.md")
      old = File.read!(target)
      loc = Valea.Icm.Locator.icm(icm.id, "Pricing/Current Pricing.md")

      pending_memory!(ws, "m4", loc, nil, "x")
      {:ok, %{revision: rev}} = Queue.get("m4")
      assert {:error, :apply_conflict} = Queue.approve("m4", rev)

      assert File.read!(target) == old
      assert File.exists?(Path.join(ws, "queue/pending/m4.json"))
      refute File.exists?(Path.join(ws, "queue/processing/m4.json"))

      base = :crypto.hash(:sha256, File.read!(target)) |> Base.encode16(case: :lower)

      pending_memory!(ws, "m5", loc, base, "y")
      # set_enabled/3 returns bare :ok (not {:ok, _}).
      :ok = Valea.Mounts.set_enabled(ws, icm.mount_key, false)
      {:ok, %{revision: rev5}} = Queue.get("m5")
      assert {:error, :apply_conflict} = Queue.approve("m5", rev5)
      :ok = Valea.Mounts.set_enabled(ws, icm.mount_key, true)

      assert File.read!(target) == old
      assert File.exists?(Path.join(ws, "queue/pending/m5.json"))
      refute File.exists?(Path.join(ws, "queue/processing/m5.json"))
    end

    # Task 7.3's core TDD scenario: the locator is never built from (or
    # resolved through) a physical path snapshotted at finalize time — it
    # re-resolves against the CURRENT mount table at approval, so a pending
    # proposal survives the ICM being re-mounted at a brand-new physical
    # location (same stable `id`, different folder — the `mount_key`
    # happens to come back "primary" again too, since it is slugified from
    # the manifest's own `name:`, unchanged by the move) between finalize
    # and approval.
    test "approval re-resolves the locator against a NEW physical location after the ICM is re-mounted (same id, new folder) — the pending proposal still applies",
         %{workspace: ws} do
      icm = mount_primary!(ws)
      loc = Valea.Icm.Locator.icm(icm.id, "Pricing/Current Pricing.md")
      old = File.read!(Path.join(icm.root, "Pricing/Current Pricing.md"))
      base = :crypto.hash(:sha256, old) |> Base.encode16(case: :lower)
      pending_memory!(ws, "mv1", loc, base, "# Pricing\n\n300\n")

      # Move the ICM's physical folder to a NEW location on disk, then
      # re-register it there — same icm.yaml `id`, a different physical
      # root.
      new_root = icm.root <> "-moved"
      {:ok, _} = Valea.Mounts.unmount(ws, icm.mount_key)
      File.rename!(icm.root, new_root)
      assert {:ok, %{id: icm_id}} = Valea.Mounts.mount(ws, new_root)
      assert icm_id == icm.id

      {:ok, %{revision: rev}} = Queue.get("mv1")
      new_target = Path.join(new_root, "Pricing/Current Pricing.md")
      assert {:ok, %{applied_path: ^new_target}} = Queue.approve("mv1", rev)
      assert File.read!(new_target) == "# Pricing\n\n300\n"
      refute File.exists?(icm.root)
    end

    # The other half of Task 7.3's core TDD scenario: an ICM that is gone
    # entirely (never re-mounted) by approval time returns the item to
    # pending/ with an apply_conflict audit, rather than applying nothing
    # while quietly discarding the proposal.
    test "unmount between finalize and approval -> apply_conflict, item back in pending", %{
      workspace: ws
    } do
      icm = mount_primary!(ws)
      loc = Valea.Icm.Locator.icm(icm.id, "Pricing/Current Pricing.md")

      base =
        :crypto.hash(:sha256, File.read!(Path.join(icm.root, "Pricing/Current Pricing.md")))
        |> Base.encode16(case: :lower)

      pending_memory!(ws, "um1", loc, base, "# Pricing\n\n400\n")

      {:ok, _} = Valea.Mounts.unmount(ws, icm.mount_key)

      {:ok, %{revision: rev}} = Queue.get("um1")
      assert {:error, :apply_conflict} = Queue.approve("um1", rev)
      assert File.exists?(Path.join(ws, "queue/pending/um1.json"))
      refute File.exists?(Path.join(ws, "queue/processing/um1.json"))

      {:ok, entries} = Valea.Audit.entries(20)
      conflict = Enum.find(entries, &(&1["type"] == "apply_conflict" and &1["run_id"] == "um1"))
      assert conflict
      assert conflict["reason"] == "icm_not_mounted"
      # Resolution itself never got anywhere — nothing to report.
      assert conflict["target"]["resolved_path"] == nil
    end

    test "malformed apply action fails envelope validation", %{workspace: ws} do
      loc = Valea.Icm.Locator.icm("00000000-0000-0000-0000-000000000000", "x.md")
      pending_memory!(ws, "m6", loc, "not-hex", "c")
      assert {:error, :queue_item_invalid} = Queue.get("m6")
    end

    test "write exception is a conflict, not an orphaned item", %{workspace: ws} do
      icm = mount_primary!(ws)
      loc = Valea.Icm.Locator.icm(icm.id, "Pricing/Current Pricing.md/evil.md")
      pending_memory!(ws, "m8", loc, nil, "x")
      {:ok, %{revision: rev}} = Queue.get("m8")

      assert {:error, :apply_conflict} = Valea.Queue.approve("m8", rev)
      assert File.exists?(Path.join(ws, "queue/pending/m8.json"))
      refute File.exists?(Path.join(ws, "queue/processing/m8.json"))

      {:ok, entries} = Valea.Audit.entries(20)
      assert Enum.any?(entries, &(&1["type"] == "apply_conflict" and &1["run_id"] == "m8"))
    end

    test "reject of a memory item lands with decided_at and no mailbox_ops", %{workspace: ws} do
      # Reject never resolves the locator (the proposed edit is only ever
      # staged, never applied), so it needs no real mount.
      loc =
        Valea.Icm.Locator.icm(
          "00000000-0000-0000-0000-000000000000",
          "Pricing/Current Pricing.md"
        )

      pending_memory!(ws, "m7", loc, String.duplicate("a", 64), "z")
      {:ok, %{revision: rev}} = Queue.get("m7")
      assert {:ok, %{}} = Queue.reject("m7", rev)
      rejected = Path.join(ws, "queue/rejected/m7.json") |> File.read!() |> Jason.decode!()
      assert rejected["decided_at"]
      refute Map.has_key?(rejected, "mailbox_ops")
    end
  end

  ## reject/3 rejection reasons (B6)

  describe "reject/3 rejection reasons" do
    # reject/3 never resolves the target locator (the proposed edit is only
    # ever staged, never applied — see Queue's moduledoc), so these need no
    # real mount; any syntactically valid locator does.
    defp dummy_memory_locator,
      do:
        Valea.Icm.Locator.icm(
          "00000000-0000-0000-0000-000000000000",
          "Pricing/Current Pricing.md"
        )

    test "reject/3 persists a trimmed reason in envelope and audit", %{workspace: ws} do
      pending_memory!(ws, "rr1", dummy_memory_locator(), String.duplicate("a", 64), "x")
      {:ok, %{revision: rev}} = Valea.Queue.get("rr1")

      assert {:ok, %{}} = Valea.Queue.reject("rr1", rev, "  too pushy  ")

      rejected = Path.join(ws, "queue/rejected/rr1.json") |> File.read!() |> Jason.decode!()
      assert rejected["decision"] == %{"reason" => "too pushy"}

      {:ok, entries} = Valea.Audit.entries(10)
      assert Enum.any?(entries, &(&1["type"] == "item_rejected" and &1["reason"] == "too pushy"))

      {:ok, decided} = Valea.Queue.list_decided()
      entry = Enum.find(decided, &(&1.run_id == "rr1"))
      assert entry.decision == %{"reason" => "too pushy"}
      assert entry.decided_at
    end

    test "reject/2 (no reason) leaves no decision key", %{workspace: ws} do
      pending_memory!(ws, "rr2", dummy_memory_locator(), String.duplicate("a", 64), "x")
      {:ok, %{revision: rev}} = Valea.Queue.get("rr2")

      assert {:ok, %{}} = Valea.Queue.reject("rr2", rev)

      rejected = Path.join(ws, "queue/rejected/rr2.json") |> File.read!() |> Jason.decode!()
      refute Map.has_key?(rejected, "decision")

      {:ok, entries} = Valea.Audit.entries(10)

      entry =
        Enum.find(entries, &(&1["type"] == "item_rejected" and &1["run_id"] == "rr2"))

      refute Map.has_key?(entry, "reason")

      {:ok, decided} = Valea.Queue.list_decided()
      entry2 = Enum.find(decided, &(&1.run_id == "rr2"))
      assert entry2.decision == nil
      assert entry2.decided_at
    end

    test "a blank/whitespace-only reason is treated the same as no reason", %{workspace: ws} do
      pending_memory!(ws, "rr3", dummy_memory_locator(), String.duplicate("a", 64), "x")
      {:ok, %{revision: rev}} = Valea.Queue.get("rr3")

      assert {:ok, %{}} = Valea.Queue.reject("rr3", rev, "   ")

      rejected = Path.join(ws, "queue/rejected/rr3.json") |> File.read!() |> Jason.decode!()
      refute Map.has_key?(rejected, "decision")
    end
  end

  ## recover/1 for memory items (B5) — decided by content hash, not a draft file

  describe "recover/1 for memory items" do
    test "apply happened, crash before terminal rename → finished", %{workspace: ws} do
      icm = mount_primary!(ws)
      target = Path.join(icm.root, "Pricing/Current Pricing.md")
      loc = Valea.Icm.Locator.icm(icm.id, "Pricing/Current Pricing.md")
      content = "# Applied\n"
      item = pending_memory!(ws, "mr1", loc, String.duplicate("0", 64), content)
      # simulate: claimed + applied, then crash
      File.mkdir_p!(Path.join(ws, "queue/processing"))

      File.rename!(
        Path.join(ws, "queue/pending/mr1.json"),
        Path.join(ws, "queue/processing/mr1.json")
      )

      File.write!(target, content)

      :ok = Valea.Queue.recover(ws)

      assert File.exists?(Path.join(ws, "queue/approved/mr1.json"))
      approved = Path.join(ws, "queue/approved/mr1.json") |> File.read!() |> Jason.decode!()
      assert approved["decided_at"]
      _ = item
    end

    test "crash before apply → handed back to pending", %{workspace: ws} do
      icm = mount_primary!(ws)
      loc = Valea.Icm.Locator.icm(icm.id, "Pricing/Current Pricing.md")
      pending_memory!(ws, "mr2", loc, String.duplicate("0", 64), "# Never applied\n")
      File.mkdir_p!(Path.join(ws, "queue/processing"))

      File.rename!(
        Path.join(ws, "queue/pending/mr2.json"),
        Path.join(ws, "queue/processing/mr2.json")
      )

      :ok = Valea.Queue.recover(ws)

      assert File.exists?(Path.join(ws, "queue/pending/mr2.json"))
      refute File.exists?(Path.join(ws, "queue/approved/mr2.json"))
    end

    test "crash after apply, but the target now holds DIFFERENT content than the envelope proposed → handed back to pending, not finished",
         %{workspace: ws} do
      # Guards against a false-positive "finished" verdict: the target file
      # exists but its bytes do not match content_markdown (e.g. a second,
      # unrelated edit landed on the same page since this item was claimed).
      icm = mount_primary!(ws)
      target = Path.join(icm.root, "Pricing/Current Pricing.md")
      loc = Valea.Icm.Locator.icm(icm.id, "Pricing/Current Pricing.md")
      pending_memory!(ws, "mr3", loc, String.duplicate("0", 64), "# Proposed\n")
      File.mkdir_p!(Path.join(ws, "queue/processing"))

      File.rename!(
        Path.join(ws, "queue/pending/mr3.json"),
        Path.join(ws, "queue/processing/mr3.json")
      )

      File.write!(target, "# Something else entirely\n")

      :ok = Valea.Queue.recover(ws)

      assert File.exists?(Path.join(ws, "queue/pending/mr3.json"))
      refute File.exists?(Path.join(ws, "queue/approved/mr3.json"))
    end

    test "finishing a recovered memory item upgrades schema to v2 and carries no mailbox_ops, no broadcast",
         %{workspace: ws} do
      icm = mount_primary!(ws)
      target = Path.join(icm.root, "Pricing/Current Pricing.md")
      loc = Valea.Icm.Locator.icm(icm.id, "Pricing/Current Pricing.md")
      content = "# Applied v2\n"
      pending_memory!(ws, "mr4", loc, String.duplicate("0", 64), content)
      File.mkdir_p!(Path.join(ws, "queue/processing"))

      File.rename!(
        Path.join(ws, "queue/pending/mr4.json"),
        Path.join(ws, "queue/processing/mr4.json")
      )

      File.write!(target, content)

      Phoenix.PubSub.subscribe(Valea.PubSub, "mail_ops")
      :ok = Valea.Queue.recover(ws)

      approved = Path.join(ws, "queue/approved/mr4.json") |> File.read!() |> Jason.decode!()
      assert approved["schema"] == "queue_item/v2"
      refute Map.has_key?(approved, "mailbox_ops")
      refute_received {:mailbox_ops_pending, "mr4"}

      {:ok, entries} = Valea.Audit.entries(50)
      entry = Enum.find(entries, &(&1["type"] == "item_approved" and &1["run_id"] == "mr4"))
      assert entry
      assert entry["recovered"] == true
    end

    test "the email recovery path is unaffected: draft-existence still decides an email item's fate",
         %{workspace: workspace} do
      id = run_id("emailrec")
      write_pending(workspace, id)
      File.mkdir_p!(Path.dirname(processing_path(workspace, id)))
      File.rename!(pending_path(workspace, id), processing_path(workspace, id))

      draft_abs = draft_path(workspace, id)
      File.mkdir_p!(Path.dirname(draft_abs))
      File.write!(draft_abs, "already executed")

      Queue.recover(workspace)

      refute File.exists?(processing_path(workspace, id))
      assert File.exists?(approved_path(workspace, id))
    end

    test "recover/1 hands a memory item back to pending when its locator no longer resolves (ICM unmounted since claim)",
         %{workspace: ws} do
      icm = mount_primary!(ws)
      loc = Valea.Icm.Locator.icm(icm.id, "Pricing/Current Pricing.md")
      pending_memory!(ws, "mr5", loc, String.duplicate("0", 64), "# Applied\n")
      File.mkdir_p!(Path.join(ws, "queue/processing"))

      File.rename!(
        Path.join(ws, "queue/pending/mr5.json"),
        Path.join(ws, "queue/processing/mr5.json")
      )

      {:ok, _} = Valea.Mounts.unmount(ws, icm.mount_key)

      :ok = Valea.Queue.recover(ws)

      assert File.exists?(Path.join(ws, "queue/pending/mr5.json"))
      refute File.exists?(Path.join(ws, "queue/approved/mr5.json"))
    end

    test "malformed memory envelope (nil locator) repends instead of raising",
         %{workspace: ws} do
      # Valid JSON, kind memory_update, but proposed_action.target.locator is
      # nil — this should be treated like any unreadable file and repended
      # safely, not raise a FunctionClauseError that poisons boot recovery.
      id = run_id("malformed")

      item = %{
        "schema" => "queue_item/v1",
        "run_id" => id,
        "workflow" => "test",
        "risk_level" => "medium",
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "payload" => %{
          "title" => "Malformed action",
          "summary" => "Testing edge case",
          "kind" => "memory_update",
          "sources" => [],
          "proposed_action" => %{
            "type" => "apply_page_content",
            "target" => %{
              "locator" => nil,
              "base_sha256" => nil,
              "content_markdown" => "content"
            }
          }
        }
      }

      processing_dir = Path.join([ws, "queue", "processing"])
      File.mkdir_p!(processing_dir)
      File.write!(Path.join(processing_dir, id <> ".json"), Jason.encode!(item))

      # This must NOT raise; recover/1 should complete successfully.
      assert :ok = Valea.Queue.recover(ws)

      # The malformed item should have been repended (treated like unreadable).
      assert File.exists?(Path.join([ws, "queue", "pending", id <> ".json"]))
      refute File.exists?(Path.join([ws, "queue", "processing", id <> ".json"]))
      refute File.exists?(Path.join([ws, "queue", "approved", id <> ".json"]))

      {:ok, entries} = Valea.Audit.entries(50)

      assert Enum.any?(entries, &(&1["type"] == "approval_recovered" and &1["run_id"] == id))
    end
  end
end
