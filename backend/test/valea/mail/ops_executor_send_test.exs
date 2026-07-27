defmodule Valea.Mail.OpsExecutorSendTest do
  # async: false — each test runs its own `Valea.Repo` against a fresh sqlite
  # file AND the single Agent-backed `FakeSmtpTransport`, so tests must not
  # overlap (same pattern as ops_executor_test.exs).
  use ExUnit.Case, async: false

  alias Valea.Mail.DraftFile
  alias Valea.Mail.OpsExecutor
  alias Valea.Mail.Settings
  alias Valea.Mail.Store
  alias Valea.Mail.SyncPass

  @raw_a """
  From: Priya Nair <priya@example.com>\r
  To: Mara <mara@example.com>\r
  Subject: Alpha\r
  Date: Wed, 15 Jul 2026 09:00:00 +0000\r
  Message-ID: <alpha@example.com>\r
  \r
  Body of alpha.\r
  """

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-opssend-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(root)

    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    previous = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous)

    start_supervised!(FakeSmtpTransport)

    on_exit(fn -> File.rm_rf!(dir) end)
    %{root: root}
  end

  # -- fixtures ---------------------------------------------------------------

  defp start_model!(opts \\ []) do
    name = :"model_#{System.unique_integer([:positive])}"
    model = ModelMailTransport.initial_model(opts)
    {:ok, _pid} = ModelMailTransport.start_link(name: name, model: model)
    name
  end

  defp smtp_block do
    %{
      host: "smtp.example.test",
      port: 587,
      security: :starttls,
      username: "mara@example.com",
      from: "mara@example.com",
      from_name: "Mara Ito"
    }
  end

  defp settings(overrides \\ %{}) do
    base = %Settings{
      slug: "mara",
      provider: :generic,
      imap: %{host: "imap.example.test", port: 993, username: "mara@example.com"},
      smtp: smtp_block(),
      folders: %{drafts: "Drafts", sent: "Sent", archive: "Archive", trash: "Trash"},
      sync: %{
        window_days: 90,
        interval_minutes: 15,
        max_message_bytes: 26_214_400,
        exclude_folders: []
      }
    }

    Map.merge(base, overrides)
  end

  defp gmail_settings do
    settings(%{
      provider: :gmail,
      folders: %{
        drafts: "[Gmail]/Drafts",
        sent: "[Gmail]/Sent Mail",
        archive: "[Gmail]/All Mail",
        trash: "[Gmail]/Trash"
      },
      sync: %{settings().sync | exclude_folders: ["[Gmail]/All Mail"]}
    })
  end

  defp connect(name) do
    {:ok, conn} = ModelMailTransport.connect(%{}, "pw", name: name)
    conn
  end

  # The send ctx: an IMAP half (`transport`/`conn`, for the Sent copy only)
  # and an SMTP half (`smtp_transport`/`smtp_credential`, for the one
  # transmit). `conn: nil` models "IMAP unavailable", which must never stop a
  # transmit — only defer the Sent copy.
  defp ctx(name, root, opts \\ []) do
    settings = Keyword.get(opts, :settings, settings())

    %{
      root: root,
      account: "mara",
      settings: settings,
      transport: ModelMailTransport,
      conn: if(name, do: connect(name), else: nil),
      smtp_transport: FakeSmtpTransport,
      smtp_credential: "smtp-pw"
    }
  end

  defp local_ctx(c), do: Map.take(c, [:root, :account, :settings])

  defp drafts_dir(root), do: Path.join([root, "sources", "mail", "mara", "drafts"])

  defp write_draft!(root, name, content) do
    dir = drafts_dir(root)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), content)
    content
  end

  defp draft_body(opts \\ []) do
    to = Keyword.get(opts, :to, "[alex@example.com]")
    extra = Keyword.get(opts, :extra, "")

    status =
      case Keyword.get(opts, :status, "draft") do
        nil -> ""
        value -> "status: #{value}\n"
      end

    """
    ---
    to: #{to}
    subject: "Re: Kickoff"
    #{status}#{extra}
    ---
    Hello Alex.
    """
  end

  defp read_draft_status(root, name) do
    {:ok, %{status: status}} =
      DraftFile.parse_and_validate(File.read!(Path.join(drafts_dir(root), name)))

    status
  end

  defp spool_wire(root, id),
    do: Path.join([root, "sources", "mail", "mara", "spool", "#{id}.wire.eml"])

  defp spool_record(root, id),
    do: Path.join([root, "sources", "mail", "mara", "spool", "#{id}.record.eml"])

  defp manifest_path(root, id),
    do: Path.join([root, "sources", "mail", "mara", "spool", "#{id}.manifest.yaml"])

  defp read_manifest(root, id) do
    {:ok, manifest} = YamlElixir.read_from_file(manifest_path(root, id))
    manifest
  end

  defp fingerprint(settings), do: OpsExecutor.review_fingerprint(settings, nil)

  defp ops_all(origin), do: Store.ops_by_origin("mara", origin)

  defp send_calls, do: FakeSmtpTransport.calls() |> Enum.filter(&(elem(&1, 0) == :send))

  # Prepares a real send op: the account's Sent folder exists on the model,
  # the draft is on disk, and `prepare_send/4` has claimed + spooled it.
  defp prepared!(root, name, opts) do
    model = Keyword.get(opts, :model)
    settings = Keyword.get(opts, :settings, settings())
    body = Keyword.get(opts, :body, draft_body())

    if model, do: ModelMailTransport.put_folder(model, settings.folders.sent)

    content = write_draft!(root, name, body)
    c = ctx(model, root, settings: settings)

    {:ok, op} =
      OpsExecutor.prepare_send(
        local_ctx(c),
        name,
        DraftFile.content_hash(content),
        fingerprint(settings)
      )

    {c, op}
  end

  defp pull!(name, root, settings) do
    {:ok, _} =
      SyncPass.run(%{
        root: root,
        account: "mara",
        settings: settings,
        credential: fn -> "pw" end,
        transport: ModelMailTransport,
        connect_opts: [name: name]
      })
  end

  # ==========================================================================
  # prepare_send — claim + snapshot + fingerprint + compose + spool
  # ==========================================================================

  describe "prepare_send" do
    test "claims, spools BOTH variants + manifest, and CAS-stamps the draft sending", %{
      root: root
    } do
      name = start_model!()

      {_c, op} =
        prepared!(root, "reply.md",
          model: name,
          body: draft_body(extra: "bcc: [hidden@example.com]")
        )

      assert op.state == "pending"

      wire = File.read!(spool_wire(root, op.id))
      record = File.read!(spool_record(root, op.id))

      # Bcc never leaves the machine on the wire; the Sent record keeps it.
      refute wire =~ "Bcc:"
      assert record =~ "Bcc: hidden@example.com"
      assert wire =~ "Message-ID: <valea.send."
      # From is config-owned, display name and all.
      assert wire =~ "From: Mara Ito <mara@example.com>"

      manifest = read_manifest(root, op.id)
      assert manifest["kind"] == "send"
      assert manifest["envelope"]["from"] == "mara@example.com"
      assert manifest["envelope"]["rcpt"] == ["alex@example.com", "hidden@example.com"]
      assert manifest["transitions"] == ["spooled"]
      assert manifest["reconcile_attempts"] == 0

      {:ok, row} = Store.op_by_id(op.id)
      assert row.wire_sha256 == sha256(wire)
      assert row.record_sha256 == sha256(record)
      assert Jason.decode!(row.envelope_rcpt) == ["alex@example.com", "hidden@example.com"]
      assert row.target_folder == "Sent"

      assert read_draft_status(root, "reply.md") == "sending"
      # Nothing was transmitted by the LOCAL phase.
      assert send_calls() == []
    end

    test "a second send on the same draft sees the existing op, creates none", %{root: root} do
      name = start_model!()
      {c, _op} = prepared!(root, "reply.md", model: name)
      content = File.read!(Path.join(drafts_dir(root), "reply.md"))

      assert {:duplicate, "sending"} =
               OpsExecutor.prepare_send(
                 local_ctx(c),
                 "reply.md",
                 DraftFile.content_hash(content),
                 fingerprint(settings())
               )

      assert [%{kind: "send"}] = Store.pending_ops("mara")
    end

    test "an active push blocks a send on the same draft", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "Drafts")
      content = write_draft!(root, "reply.md", draft_body())
      hash = DraftFile.content_hash(content)
      c = ctx(name, root)

      {:ok, _push} = OpsExecutor.prepare_push(local_ctx(c), "reply.md", hash)

      # The push's own `pushing` stamp moved the file, so re-hash from disk.
      current = File.read!(Path.join(drafts_dir(root), "reply.md"))

      assert {:duplicate, "pushing"} =
               OpsExecutor.prepare_send(
                 local_ctx(c),
                 "reply.md",
                 DraftFile.content_hash(current),
                 fingerprint(settings())
               )

      assert [%{kind: "append"}] = Store.pending_ops("mara")
    end

    test "a review fingerprint from different settings rejects re_review_required, claims nothing",
         %{root: root} do
      name = start_model!()
      content = write_draft!(root, "reply.md", draft_body())
      c = ctx(name, root)

      stale = fingerprint(settings(%{smtp: %{smtp_block() | from_name: "Someone Else"}}))

      assert {:error, "re_review_required"} =
               OpsExecutor.prepare_send(
                 local_ctx(c),
                 "reply.md",
                 DraftFile.content_hash(content),
                 stale
               )

      assert ops_all("drafts/reply.md") == []
      assert read_draft_status(root, "reply.md") == "draft"
      refute File.exists?(Path.join([root, "sources", "mail", "mara", "spool"]))
    end

    test "threading presence drift moves the fingerprint, so the send rejects", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: Date.utc_today())
      pull!(name, root, settings())
      referenced = hd(Store.occurrences("mara", "INBOX")).msg_id

      content = write_draft!(root, "reply.md", draft_body(extra: "in_reply_to: #{referenced}"))
      c = ctx(name, root)

      # The fingerprint the human reviewed carried the resolved thread.
      reviewed =
        OpsExecutor.review_fingerprint(settings(), %{
          in_reply_to: "<alpha@example.com>",
          references: ["<alpha@example.com>"]
        })

      assert {:ok, op} =
               OpsExecutor.prepare_send(
                 local_ctx(c),
                 "reply.md",
                 DraftFile.content_hash(content),
                 reviewed
               )

      assert File.read!(spool_wire(root, op.id)) =~ "In-Reply-To: <alpha@example.com>"

      # Now the referenced message leaves the mirror: the same reviewed
      # fingerprint no longer matches, so a fresh send refuses.
      Store.transition_op(op.id, "rejected", %{error: "test"})
      Store.clear_folder("mara", "INBOX")
      current = File.read!(Path.join(drafts_dir(root), "reply.md"))

      assert {:error, "re_review_required"} =
               OpsExecutor.prepare_send(
                 local_ctx(c),
                 "reply.md",
                 DraftFile.content_hash(current),
                 reviewed
               )
    end

    test "a draft larger than sync.max_message_bytes rejects, claims nothing", %{root: root} do
      name = start_model!()
      tiny = settings(%{sync: %{settings().sync | max_message_bytes: 10}})
      content = write_draft!(root, "reply.md", draft_body())
      c = ctx(name, root, settings: tiny)

      assert {:error, "draft_too_large"} =
               OpsExecutor.prepare_send(
                 local_ctx(c),
                 "reply.md",
                 DraftFile.content_hash(content),
                 fingerprint(tiny)
               )

      assert ops_all("drafts/reply.md") == []
    end

    # Unlike the push (which claims first and rejects the claimed row), every
    # send refusal happens BEFORE the claim — so a stale hash leaves no ledger
    # trace at all, and the draft's own claim stays free.
    test "a content_hash mismatch refuses before claiming anything", %{root: root} do
      name = start_model!()
      write_draft!(root, "reply.md", draft_body())
      c = ctx(name, root)

      assert {:error, "content_changed"} =
               OpsExecutor.prepare_send(
                 local_ctx(c),
                 "reply.md",
                 DraftFile.content_hash("what the reviewer saw earlier"),
                 fingerprint(settings())
               )

      assert ops_all("drafts/reply.md") == []
      assert read_draft_status(root, "reply.md") == "draft"
      assert send_calls() == []
    end

    test "a symlinked draft is refused at the no-follow open, before any claim", %{root: root} do
      name = start_model!()
      File.mkdir_p!(drafts_dir(root))
      outside = Path.join(root, "secret.md")
      File.write!(outside, draft_body())
      File.ln_s!(outside, Path.join(drafts_dir(root), "reply.md"))
      c = ctx(name, root)

      assert {:error, "not_found"} =
               OpsExecutor.prepare_send(
                 local_ctx(c),
                 "reply.md",
                 DraftFile.content_hash(draft_body()),
                 fingerprint(settings())
               )

      assert ops_all("drafts/reply.md") == []
    end

    # The send identity must survive the engine's own status stamps: a draft
    # that had no `status:` line gets one on its first attempt, so hashing the
    # RAW bytes would give the retry a different Message-ID (and the recipient
    # a duplicate instead of a dedupe).
    test "the send Message-ID is stable across a failed attempt's stamps", %{root: root} do
      name = start_model!()
      {c, first} = prepared!(root, "reply.md", model: name, body: draft_body(status: nil))

      FakeSmtpTransport.script([{:send, :_, {:error, :auth_failed}}])
      assert {:rejected, _} = OpsExecutor.execute_send(c, first.id)
      assert read_draft_status(root, "reply.md") == "draft"

      # The file now carries a status line it never had — a new raw hash.
      current = File.read!(Path.join(drafts_dir(root), "reply.md"))
      assert DraftFile.content_hash(current) != first.content_hash

      {:ok, second} =
        OpsExecutor.prepare_send(
          local_ctx(c),
          "reply.md",
          DraftFile.content_hash(current),
          fingerprint(settings())
        )

      assert second.message_id == first.message_id
    end
  end

  # ==========================================================================
  # execute_send — the one transmit + the Sent copy
  # ==========================================================================

  describe "execute_send (generic profile)" do
    test "accepted: transmits once, files the RECORD in Sent, completes, stamps sent", %{
      root: root
    } do
      name = start_model!()

      {c, op} =
        prepared!(root, "reply.md",
          model: name,
          body: draft_body(extra: "bcc: [hidden@example.com]")
        )

      FakeSmtpTransport.script([{:send, :_, {:ok, :accepted}}])

      assert :ok = OpsExecutor.execute_send(c, op.id)

      assert [{:send, [config, credential, envelope, data, opts]}] = send_calls()
      assert config.host == "smtp.example.test"
      assert config.security == :starttls
      assert credential == "smtp-pw"

      assert envelope == %{
               from: "mara@example.com",
               rcpt: ["alex@example.com", "hidden@example.com"]
             }

      refute data =~ "Bcc:"
      assert opts == []

      # The Sent copy is the RECORD variant (Bcc kept), filed once, seen.
      assert [filed] = ModelMailTransport.messages(name, "Sent")
      assert filed.raw =~ "Bcc: hidden@example.com"
      assert "\\Seen" in filed.flags

      assert {:ok, %{state: "complete", error: nil}} = Store.op_by_id(op.id)
      assert read_draft_status(root, "reply.md") == "sent"
      refute File.exists?(spool_wire(root, op.id))
      refute File.exists?(spool_record(root, op.id))
      refute File.exists?(manifest_path(root, op.id))
    end

    test "rejected recipients: op rejected with the joined per-recipient reasons, draft reverts",
         %{root: root} do
      name = start_model!()

      {c, op} =
        prepared!(root, "reply.md",
          model: name,
          body: draft_body(to: "[alex@example.com, sam@example.com]")
        )

      FakeSmtpTransport.script([
        {:send, :_,
         {:error,
          {:rejected_recipients,
           [{"alex@example.com", "550 no such user"}, {"sam@example.com", "552 over quota"}]}}}
      ])

      assert {:rejected, reason} = OpsExecutor.execute_send(c, op.id)
      assert reason =~ "alex@example.com: 550 no such user"
      assert reason =~ "sam@example.com: 552 over quota"

      assert {:ok, %{state: "rejected", error: ^reason}} = Store.op_by_id(op.id)
      assert ModelMailTransport.messages(name, "Sent") == []
      assert read_draft_status(root, "reply.md") == "draft"
      assert length(send_calls()) == 1
      refute File.exists?(spool_wire(root, op.id))
    end

    test "a received final 5xx after the dot is provably unsent: rejected, draft reverts", %{
      root: root
    } do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      FakeSmtpTransport.script([{:send, :_, {:error, {:refused, 550, "policy rejection"}}}])

      assert {:rejected, reason} = OpsExecutor.execute_send(c, op.id)
      assert reason =~ "550"
      assert {:ok, %{state: "rejected"}} = Store.op_by_id(op.id)
      assert read_draft_status(root, "reply.md") == "draft"
      assert ModelMailTransport.messages(name, "Sent") == []
      assert length(send_calls()) == 1
    end

    test "an unknown outcome parks send_review with the spool kept, sending exactly once", %{
      root: root
    } do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      FakeSmtpTransport.script([{:send, :_, {:unknown, :closed}}])

      assert {:send_review, reason} = OpsExecutor.execute_send(c, op.id)
      assert reason =~ "closed"
      assert {:ok, %{state: "send_review"}} = Store.op_by_id(op.id)

      # The spool survives for the human resolution / gmail reconciliation.
      assert File.exists?(spool_wire(root, op.id))
      assert File.exists?(spool_record(root, op.id))
      assert File.exists?(manifest_path(root, op.id))
      # The draft stays `sending` — it is NOT provably unsent.
      assert read_draft_status(root, "reply.md") == "sending"
      assert length(send_calls()) == 1

      # And the parked op never transmits again, however often it is driven.
      assert {:send_review, "awaiting_resolution"} = OpsExecutor.execute_send(c, op.id)
      OpsExecutor.recover(c)
      assert length(send_calls()) == 1
      assert {:ok, %{state: "send_review"}} = Store.op_by_id(op.id)
    end

    test "a tampered wire payload rejects BEFORE the transport is ever called", %{root: root} do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      File.write!(spool_wire(root, op.id), "tampered bytes that don't match the recorded hash")

      assert {:rejected, "payload_hash_mismatch"} = OpsExecutor.execute_send(c, op.id)
      assert send_calls() == []
      assert {:ok, %{state: "rejected"}} = Store.op_by_id(op.id)
      assert read_draft_status(root, "reply.md") == "draft"
    end

    # The CAS stamp rule, applied to the irreversible step: the human edits the
    # draft while the send is in flight. What was reviewed is what goes out —
    # and the NEWER revision on disk is left completely untouched (it is an
    # unsent draft again, which is exactly what the display projection reports).
    test "a draft edited mid-send is never stamped; the reviewed revision still goes out", %{
      root: root
    } do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      edited = draft_body(status: "sending", extra: "cc: [sam@example.com]")
      write_draft!(root, "reply.md", edited)

      FakeSmtpTransport.script([{:send, :_, {:ok, :accepted}}])
      assert :ok = OpsExecutor.execute_send(c, op.id)

      # The transmitted message is the REVIEWED one — the added cc never
      # reached the envelope or the headers.
      assert [{:send, [_config, _credential, envelope, data, _opts]}] = send_calls()
      assert envelope.rcpt == ["alex@example.com"]
      refute data =~ "sam@example.com"

      # And the newer revision on disk was left exactly as the human wrote it.
      assert File.read!(Path.join(drafts_dir(root), "reply.md")) == edited
    end

    test "an op id from another account raises instead of transmitting", %{root: root} do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      assert_raise ArgumentError, fn ->
        OpsExecutor.execute_send(%{c | account: "other"}, op.id)
      end

      assert send_calls() == []
      assert {:ok, %{state: "pending"}} = Store.op_by_id(op.id)
    end

    test "with no IMAP connection the mail still goes out; the Sent copy resumes on recover", %{
      root: root
    } do
      name = start_model!()
      ModelMailTransport.put_folder(name, "Sent")
      content = write_draft!(root, "reply.md", draft_body())
      offline = ctx(nil, root)

      {:ok, op} =
        OpsExecutor.prepare_send(
          local_ctx(offline),
          "reply.md",
          DraftFile.content_hash(content),
          fingerprint(settings())
        )

      FakeSmtpTransport.script([{:send, :_, {:ok, :accepted}}])

      assert {:sending, _notice} = OpsExecutor.execute_send(offline, op.id)
      assert {:ok, %{state: "transmitted"}} = Store.op_by_id(op.id)
      assert ModelMailTransport.messages(name, "Sent") == []

      # The next IMAP-connected pass files the Sent copy — with NO transmit.
      OpsExecutor.recover(ctx(name, root))

      assert length(ModelMailTransport.messages(name, "Sent")) == 1
      assert {:ok, %{state: "complete"}} = Store.op_by_id(op.id)
      assert length(send_calls()) == 1
    end

    test "a Sent-copy append failure completes with a notice — a sent mail is never un-sent", %{
      root: root
    } do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      FakeSmtpTransport.script([{:send, :_, {:ok, :accepted}}])
      ModelMailTransport.inject(name, {:fail, :append, :mailbox_full})

      assert :ok = OpsExecutor.execute_send(c, op.id)

      assert {:ok, %{state: "complete", error: "sent_copy_failed"}} = Store.op_by_id(op.id)
      assert read_draft_status(root, "reply.md") == "sent"
      # The record payload is KEPT so the retry affordance has something to file.
      assert File.exists?(spool_record(root, op.id))

      # retry_sent_copy re-runs ONLY the append.
      assert :ok = OpsExecutor.retry_sent_copy(c, op.id)
      assert length(ModelMailTransport.messages(name, "Sent")) == 1
      assert {:ok, %{state: "complete", error: nil}} = Store.op_by_id(op.id)
      assert length(send_calls()) == 1
      refute File.exists?(spool_record(root, op.id))
    end

    test "retry_sent_copy refuses an op that is not a completed sent_copy_failed", %{root: root} do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      assert {:error, :not_retryable} = OpsExecutor.retry_sent_copy(c, op.id)
      assert {:error, :not_retryable} = OpsExecutor.retry_sent_copy(c, "no-such-op")
      assert send_calls() == []
    end

    test "the Sent copy is search-first: an already-filed Message-ID is never appended twice", %{
      root: root
    } do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      # Another client (or a previous attempt) already filed the record.
      ModelMailTransport.put_message(name, "Sent", File.read!(spool_record(root, op.id)))

      FakeSmtpTransport.script([{:send, :_, {:ok, :accepted}}])
      assert :ok = OpsExecutor.execute_send(c, op.id)

      assert length(ModelMailTransport.messages(name, "Sent")) == 1
      assert {:ok, %{state: "complete", error: nil}} = Store.op_by_id(op.id)
    end
  end

  describe "execute_send (gmail profile)" do
    test "accepted: completes without any APPEND — Google files Sent Mail itself", %{root: root} do
      name = start_model!(gmail: true)
      {c, op} = prepared!(root, "reply.md", model: name, settings: gmail_settings())

      FakeSmtpTransport.script([{:send, :_, {:ok, :accepted}}])

      assert :ok = OpsExecutor.execute_send(c, op.id)

      assert ModelMailTransport.messages(name, "[Gmail]/Sent Mail") == []
      assert {:ok, %{state: "complete", error: nil}} = Store.op_by_id(op.id)
      assert read_draft_status(root, "reply.md") == "sent"
      assert length(send_calls()) == 1
    end

    test "an unknown outcome reconciles from Sent Mail: found → complete, no second transmit", %{
      root: root
    } do
      name = start_model!(gmail: true)
      {c, op} = prepared!(root, "reply.md", model: name, settings: gmail_settings())

      FakeSmtpTransport.script([{:send, :_, {:unknown, :timeout}}])
      assert {:send_review, _} = OpsExecutor.execute_send(c, op.id)

      # Gmail filed it after all (the 250 was lost, not the message).
      ModelMailTransport.put_message(
        name,
        "[Gmail]/Sent Mail",
        File.read!(spool_record(root, op.id))
      )

      OpsExecutor.recover(c)

      assert {:ok, %{state: "complete"}} = Store.op_by_id(op.id)
      assert read_draft_status(root, "reply.md") == "sent"
      assert length(send_calls()) == 1
      # Reconciliation proved it; it never appended a copy of its own.
      assert length(ModelMailTransport.messages(name, "[Gmail]/Sent Mail")) == 1
    end

    test "three empty Sent Mail checks park the op with the checked-and-empty notice", %{
      root: root
    } do
      name = start_model!(gmail: true)
      {c, op} = prepared!(root, "reply.md", model: name, settings: gmail_settings())

      FakeSmtpTransport.script([{:send, :_, {:unknown, :closed}}])
      assert {:send_review, _} = OpsExecutor.execute_send(c, op.id)

      for _attempt <- 1..3, do: OpsExecutor.recover(c)

      assert {:ok, %{state: "send_review", error: "gmail_sent_checked_empty"}} =
               Store.op_by_id(op.id)

      assert read_manifest(root, op.id)["reconcile_attempts"] == 3
      # Never auto-rejected, never re-transmitted.
      assert length(send_calls()) == 1
      assert File.exists?(spool_wire(root, op.id))
    end
  end

  # ==========================================================================
  # Human resolution of a parked send
  # ==========================================================================

  describe "resolve_send_review" do
    defp parked!(root, opts) do
      {c, op} = prepared!(root, "reply.md", opts)
      FakeSmtpTransport.script([{:send, :_, {:unknown, :closed}}])
      assert {:send_review, _} = OpsExecutor.execute_send(c, op.id)
      {c, op}
    end

    test ":sent runs the idempotent Sent copy and completes", %{root: root} do
      name = start_model!()
      {c, op} = parked!(root, model: name)

      # The mail really did go out and the user says so; a copy is already
      # in Sent, so the idempotent step must not file a second one.
      ModelMailTransport.put_message(name, "Sent", File.read!(spool_record(root, op.id)))

      assert :ok = OpsExecutor.resolve_send_review(c, op.id, :sent)

      assert length(ModelMailTransport.messages(name, "Sent")) == 1
      assert {:ok, %{state: "complete"}} = Store.op_by_id(op.id)
      assert read_draft_status(root, "reply.md") == "sent"
      assert length(send_calls()) == 1
    end

    test ":not_sent rejects the op and reverts the draft for a fresh click", %{root: root} do
      name = start_model!()
      {c, op} = parked!(root, model: name)

      assert :ok = OpsExecutor.resolve_send_review(c, op.id, :not_sent)

      assert {:ok, %{state: "rejected", error: "resolved_not_sent"}} = Store.op_by_id(op.id)
      assert read_draft_status(root, "reply.md") == "draft"
      assert ModelMailTransport.messages(name, "Sent") == []
      assert length(send_calls()) == 1
      refute File.exists?(spool_wire(root, op.id))
    end

    test "refuses an op that is not parked, or belongs to another account", %{root: root} do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      assert {:error, :not_reviewable} = OpsExecutor.resolve_send_review(c, op.id, :sent)
      assert {:error, :not_reviewable} = OpsExecutor.resolve_send_review(c, "no-such-op", :sent)

      Store.transition_op(op.id, "send_review", %{error: "closed"})

      assert {:error, :not_reviewable} =
               OpsExecutor.resolve_send_review(%{c | account: "other"}, op.id, :sent)

      assert send_calls() == []
    end
  end

  # ==========================================================================
  # Crash recovery — the local classification pass (NO network)
  # ==========================================================================

  describe "classify_sends_local" do
    test "classifies each in-flight state without touching the network", %{root: root} do
      name = start_model!()
      lc = local_ctx(ctx(name, root))

      rows =
        for {origin, state} <- [
              {"drafts/a.md", "claimed"},
              {"drafts/b.md", "pending"},
              {"drafts/c.md", "executing"},
              {"drafts/d.md", "transmitted"},
              {"drafts/e.md", "send_review"}
            ] do
          {:ok, op} =
            Store.create_pending_op(%{
              kind: "send",
              account: "mara",
              origin: origin,
              target_folder: "Sent",
              message_id: "<valea.send.#{origin}@valea.invalid>",
              msg_id: Path.basename(origin),
              state: state
            })

          {state, op.id}
        end
        |> Map.new()

      assert :ok = OpsExecutor.classify_sends_local(lc)

      assert {:ok, %{state: "rejected", error: "crashed_before_spool"}} =
               Store.op_by_id(rows["claimed"])

      assert {:ok, %{state: "rejected", error: "crashed_before_transmit"}} =
               Store.op_by_id(rows["pending"])

      assert {:ok, %{state: "send_review", error: "crashed_during_transmit"}} =
               Store.op_by_id(rows["executing"])

      assert {:ok, %{state: "transmitted"}} = Store.op_by_id(rows["transmitted"])
      assert {:ok, %{state: "send_review", error: nil}} = Store.op_by_id(rows["send_review"])
      assert send_calls() == []
    end

    test "a send stranded pre-transmit reverts its draft and frees the claim", %{root: root} do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      assert :ok = OpsExecutor.classify_sends_local(local_ctx(c))

      assert {:ok, %{state: "rejected", error: "crashed_before_transmit"}} = Store.op_by_id(op.id)
      assert read_draft_status(root, "reply.md") == "draft"
      refute File.exists?(spool_wire(root, op.id))
      assert send_calls() == []

      # The claim is free again: the human can review and click Send afresh.
      current = File.read!(Path.join(drafts_dir(root), "reply.md"))

      assert {:ok, _fresh} =
               OpsExecutor.prepare_send(
                 local_ctx(c),
                 "reply.md",
                 DraftFile.content_hash(current),
                 fingerprint(settings())
               )
    end

    test "append ops are left entirely alone", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "Drafts")
      content = write_draft!(root, "reply.md", draft_body())
      c = ctx(name, root)

      {:ok, push} =
        OpsExecutor.prepare_push(local_ctx(c), "reply.md", DraftFile.content_hash(content))

      assert :ok = OpsExecutor.classify_sends_local(local_ctx(c))

      assert {:ok, %{state: "pending"}} = Store.op_by_id(push.id)
    end
  end

  # ==========================================================================
  # Database-loss recovery — orphan send manifests
  # ==========================================================================

  describe "orphan send manifests" do
    defp wipe_ledger! do
      Enum.each(Store.pending_ops("mara"), fn %{id: id} ->
        {:ok, row} = Ash.get(Valea.Mail.Store.PendingOp, id)
        Ash.destroy!(row)
      end)
    end

    test "a manifest whose last transition is `spooled` recreates as pending — never transmits",
         %{
           root: root
         } do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      wipe_ledger!()
      OpsExecutor.recover(c)

      assert {:ok, %{state: "pending", kind: "send"}} = Store.op_by_id(op.id)
      assert send_calls() == []
      assert ModelMailTransport.messages(name, "Sent") == []
    end

    test "a manifest that reached `transmitting` recreates at-or-past DATA → send_review", %{
      root: root
    } do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      FakeSmtpTransport.script([{:send, :_, {:unknown, :closed}}])
      OpsExecutor.execute_send(c, op.id)
      wipe_ledger!()

      OpsExecutor.recover(c)

      assert {:ok, %{state: "send_review"}} = Store.op_by_id(op.id)
      assert length(send_calls()) == 1
    end

    test "a manifest that reached `transmitted` recreates transmitted and resumes the Sent copy",
         %{root: root} do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      FakeSmtpTransport.script([{:send, :_, {:ok, :accepted}}])
      ModelMailTransport.inject(name, {:fail, :append, :boom})
      OpsExecutor.execute_send(c, op.id)
      # Completed-with-notice keeps the spool; drop the row to model DB loss
      # mid-flight with the Sent copy still outstanding.
      Store.transition_op(op.id, "transmitted", %{error: nil})
      wipe_ledger!()

      OpsExecutor.recover(c)

      assert {:ok, %{state: "complete", error: nil}} = Store.op_by_id(op.id)
      assert length(ModelMailTransport.messages(name, "Sent")) == 1
      assert length(send_calls()) == 1
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
