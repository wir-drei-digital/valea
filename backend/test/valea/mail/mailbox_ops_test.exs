defmodule Valea.Mail.MailboxOpsTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Mail.MailboxOps
  alias Valea.Mail.Message
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Settings

  @drafts "Drafts"
  @review "AI/Review"
  @processed "AI/Processed"

  setup do
    ws = AgentCase.open_workspace!()
    {:ok, _} = FakeMailTransport.start_link()
    %{root: ws.path}
  end

  # -- fixtures ---------------------------------------------------------------

  defp settings do
    %Settings{
      account: "mara@example.com",
      imap: %{host: "imap.example.com", port: 993, username: "mara@example.com"},
      folders: %{review: @review, processed: @processed, drafts: @drafts}
    }
  end

  defp credential, do: fn -> "app-password" end

  defp run_id(suffix), do: "20260710T000000Z-#{suffix}"

  # An imap-source message file (parseable, non-seed) with a UID to move.
  defp write_source_message(root, suffix, uid) do
    msg_id = "2026-07-09-priya-#{suffix}"
    rel = Path.join(["sources", "mail", "messages", "#{msg_id}.md"])
    abs = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(abs))

    message = %Message{
      message_id: "<orig-#{suffix}@mail.example.com>",
      from: %{name: "Priya Nair", email: "priya@example.com"},
      to: [],
      subject: "Inquiry",
      date: ~U[2026-07-09 10:00:00Z],
      references: ["<thread-root@example.com>"],
      reply_to: nil,
      in_reply_to: nil,
      body_text: "Original inquiry body.\n",
      attachments: [],
      notes: %{}
    }

    bytes =
      MessageFile.render(message, %{
        msg_id: msg_id,
        uid: uid,
        status: "review",
        source: "imap",
        attachments: []
      })

    File.write!(abs, bytes)
    %{rel: rel, abs: abs, msg_id: msg_id}
  end

  defp write_draft(root, run_id) do
    rel = Path.join(["sources", "mail", "drafts", "#{run_id}.md"])
    abs = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(abs))

    File.write!(abs, """
    ---
    to: priya@example.com
    subject: Re: Inquiry
    run_id: #{run_id}
    workflow: icm/Workflows/New Inquiry Triage.md
    sources:
      - icm/Clients/Priya Nair.md
    ---

    Hello Priya,\n\nThanks for reaching out!\n
    """)

    abs
  end

  # Plants a decided envelope directly in queue/<dir>/<run_id>.json with the
  # given mailbox_ops, mirroring what Queue.approve/reject would have written.
  defp plant_envelope(root, run_id, dir, ops, source_rel) do
    envelope = %{
      "schema" => "queue_item/v2",
      "run_id" => run_id,
      "workflow" => "icm/Workflows/New Inquiry Triage.md",
      "risk_level" => "medium",
      "created_at" => "2026-07-10T00:00:00Z",
      "source_message" => source_rel,
      "payload" => %{
        "schema" => "proposal/v1",
        "kind" => "email_draft",
        "title" => "Reply to Priya",
        "summary" => "Draft a warm reply",
        "sources" => ["icm/Clients/Priya Nair.md"],
        "proposed_action" => %{
          "type" => "create_email_draft",
          "to" => "priya@example.com",
          "subject" => "Re: Inquiry",
          "body_markdown" => "Hello Priya,\n"
        }
      },
      "mailbox_ops" => ops
    }

    path = Path.join([root, "queue", dir, "#{run_id}.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(envelope))
    path
  end

  defp decided_ops(run_id) do
    {:ok, %{item: item}} = Valea.Queue.get_decided(run_id)
    item["mailbox_ops"]
  end

  defp audit_types do
    {:ok, entries} = Valea.Audit.entries(100)
    Enum.map(entries, & &1["type"])
  end

  defp execute(root, run_id) do
    MailboxOps.execute(%{
      root: root,
      run_id: run_id,
      transport: FakeMailTransport,
      settings: settings(),
      credential: credential()
    })
  end

  # -- happy path -------------------------------------------------------------

  test "happy path: search miss appends the draft, moves the source, marks both ops done", %{
    root: root
  } do
    id = run_id("happy1")
    source = write_source_message(root, "happy1", 42)
    write_draft(root, id)

    plant_envelope(root, id, "approved", both_pending(), source.rel)

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, [:_, @drafts], {:ok, %{uidvalidity: 1, uidnext: 10}}},
      {:uid_search, :_, {:ok, []}},
      {:append, :_, :ok},
      {:select, [:_, @review], {:ok, %{uidvalidity: 1, uidnext: 50}}},
      {:uid_move, :_, :ok},
      {:logout, :_, :ok}
    ])

    assert :ok = execute(root, id)

    ops = decided_ops(id)
    assert ops["draft_append"]["status"] == "done"
    assert ops["archive_source"]["status"] == "done"

    # the source file's status flipped locally to processed
    assert File.read!(source.abs) =~ "status: processed"

    types = audit_types()
    assert "draft_appended" in types
    assert "message_archived" in types

    # exactly one APPEND, with the deterministic draft Message-ID in the body
    appends = for {:append, args} <- FakeMailTransport.calls(), do: args
    assert [[_conn, @drafts, ["\\Draft"], rfc822]] = appends
    assert rfc822 =~ "<valea.draft.#{id}@valea.invalid>"
    # moved to the processed folder
    assert [[_conn, 42, @processed]] = for({:uid_move, a} <- FakeMailTransport.calls(), do: a)
  end

  test "search hit: the draft is already in Drafts, so no APPEND is issued and the op is done", %{
    root: root
  } do
    id = run_id("hit1")
    source = write_source_message(root, "hit1", 43)
    write_draft(root, id)
    plant_envelope(root, id, "approved", both_pending(), source.rel)

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, [:_, @drafts], {:ok, %{uidvalidity: 1, uidnext: 10}}},
      {:uid_search, :_, {:ok, [7]}},
      {:select, [:_, @review], {:ok, %{uidvalidity: 1, uidnext: 50}}},
      {:uid_move, :_, :ok},
      {:logout, :_, :ok}
    ])

    assert :ok = execute(root, id)

    assert decided_ops(id)["draft_append"]["status"] == "done"

    called = FakeMailTransport.calls() |> Enum.map(&elem(&1, 0))
    refute :append in called

    # a search hit records the recovered-flag audit
    {:ok, entries} = Valea.Audit.entries(100)
    draft_audit = Enum.find(entries, &(&1["type"] == "draft_appended" and &1["run_id"] == id))
    assert draft_audit["recovered"] == true
  end

  # -- unsupported move -------------------------------------------------------

  test "unsupported move: op is 'unsupported' but the local status still flips", %{root: root} do
    id = run_id("unsup1")
    source = write_source_message(root, "unsup1", 44)
    plant_envelope(root, id, "rejected", archive_only_pending(), source.rel)

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, [:_, @review], {:ok, %{uidvalidity: 1, uidnext: 50}}},
      {:uid_move, :_, {:unsupported, "server has neither MOVE nor UIDPLUS"}},
      {:logout, :_, :ok}
    ])

    assert :ok = execute(root, id)

    assert decided_ops(id)["archive_source"]["status"] == "unsupported"
    # reviewed is reviewed: local file flips even though the server couldn't move
    assert File.read!(source.abs) =~ "status: processed"
  end

  # -- connect failure --------------------------------------------------------

  test "connect failure: every pending op is marked failed and the approval is untouched", %{
    root: root
  } do
    id = run_id("conn1")
    source = write_source_message(root, "conn1", 45)
    write_draft(root, id)
    approved_path = plant_envelope(root, id, "approved", both_pending(), source.rel)

    FakeMailTransport.script([
      {:connect, :_, {:error, :timeout}}
    ])

    assert :ok = execute(root, id)

    ops = decided_ops(id)
    assert ops["draft_append"]["status"] == "failed"
    assert ops["archive_source"]["status"] == "failed"
    assert ops["draft_append"]["error"] =~ "timeout"

    # approval untouched: the envelope stays in approved/, source not flipped
    assert File.exists?(approved_path)
    assert File.read!(source.abs) =~ "status: review"

    # no folder/append/move calls happened past the failed connect
    called = FakeMailTransport.calls() |> Enum.map(&elem(&1, 0))
    assert called == [:connect]

    assert "op_failed" in audit_types()
  end

  # -- seed / terminal no-ops -------------------------------------------------

  test "a seed-skipped envelope makes zero transport calls", %{root: root} do
    id = run_id("seed1")
    plant_envelope(root, id, "approved", both_skipped(), nil)

    # No script needed: nothing should be called. connect must never happen.
    assert :ok = execute(root, id)

    assert FakeMailTransport.calls() == []
    ops = decided_ops(id)
    assert ops["draft_append"]["status"] == "skipped"
    assert ops["archive_source"]["status"] == "skipped"
  end

  test "an already-done op is not re-run; only the still-pending op executes", %{root: root} do
    id = run_id("mixed1")
    source = write_source_message(root, "mixed1", 46)
    write_draft(root, id)

    ops = %{
      "draft_append" => %{"status" => "done"},
      "archive_source" => %{"status" => "pending"}
    }

    plant_envelope(root, id, "approved", ops, source.rel)

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, [:_, @review], {:ok, %{uidvalidity: 1, uidnext: 50}}},
      {:uid_move, :_, :ok},
      {:logout, :_, :ok}
    ])

    assert :ok = execute(root, id)

    # draft_append stayed done, was never appended again
    called = FakeMailTransport.calls() |> Enum.map(&elem(&1, 0))
    refute :append in called
    refute :uid_search in called
    assert decided_ops(id)["archive_source"]["status"] == "done"
  end

  test "a move transport error marks archive_source failed without touching the local file", %{
    root: root
  } do
    id = run_id("moveerr1")
    source = write_source_message(root, "moveerr1", 47)
    plant_envelope(root, id, "rejected", archive_only_pending(), source.rel)

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, [:_, @review], {:ok, %{uidvalidity: 1, uidnext: 50}}},
      {:uid_move, :_, {:error, :no_such_uid}},
      {:logout, :_, :ok}
    ])

    assert :ok = execute(root, id)

    ops = decided_ops(id)
    assert ops["archive_source"]["status"] == "failed"
    assert ops["archive_source"]["error"] =~ "no_such_uid"
    # a real failure leaves the local status alone (still review)
    assert File.read!(source.abs) =~ "status: review"
  end

  test "a gone run_id is a harmless no-op", %{root: root} do
    assert :ok = execute(root, run_id("ghost"))
    assert FakeMailTransport.calls() == []
  end

  # -- ops shorthands ---------------------------------------------------------

  defp both_pending do
    %{"draft_append" => %{"status" => "pending"}, "archive_source" => %{"status" => "pending"}}
  end

  defp both_skipped do
    %{"draft_append" => %{"status" => "skipped"}, "archive_source" => %{"status" => "skipped"}}
  end

  defp archive_only_pending do
    %{"archive_source" => %{"status" => "pending"}}
  end
end
