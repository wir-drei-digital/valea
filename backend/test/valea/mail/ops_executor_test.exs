defmodule Valea.Mail.OpsExecutorTest do
  # async: false — each test runs its own `Valea.Repo` against a fresh sqlite
  # file (same pattern as sync_pass_test.exs), so tests must not overlap.
  use ExUnit.Case, async: false

  alias Valea.Mail.Maildir
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

  @raw_b """
  From: Devon Okoro <devon@example.com>\r
  To: Mara <mara@example.com>\r
  Subject: Beta\r
  Date: Wed, 15 Jul 2026 10:00:00 +0000\r
  Message-ID: <beta@example.com>\r
  \r
  Body of beta.\r
  """

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-opsexec-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(root)

    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    previous = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous)

    on_exit(fn -> File.rm_rf!(dir) end)
    %{root: root}
  end

  # -- model / settings / ctx helpers -----------------------------------------

  defp start_model!(opts \\ []) do
    name = :"model_#{System.unique_integer([:positive])}"
    model = ModelMailTransport.initial_model(opts)
    {:ok, _pid} = ModelMailTransport.start_link(name: name, model: model)
    name
  end

  defp settings(overrides \\ %{}) do
    base = %Settings{
      slug: "mara",
      provider: :generic,
      imap: %{host: "imap.example.test", port: 993, username: "mara@example.com"},
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

  defp connect(name) do
    {:ok, conn} = ModelMailTransport.connect(%{}, "pw", name: name)
    conn
  end

  defp ctx(name, root, opts \\ []) do
    settings = Keyword.get(opts, :settings, settings())

    %{
      root: root,
      account: "mara",
      settings: settings,
      transport: ModelMailTransport,
      conn: connect(name)
    }
    |> maybe_opid(Keyword.get(opts, :opid))
  end

  defp maybe_opid(ctx, nil), do: ctx
  defp maybe_opid(ctx, opid), do: Map.put(ctx, :opid, opid)

  # Runs a full pull pass so the model's folders/messages are mirrored into
  # the local maildir + Store + views (the executor's real starting state).
  defp pull!(name, root, settings \\ settings()) do
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

  defp recent_date, do: Date.add(Date.utc_today(), -2)

  defp msg_id_in(folder), do: hd(Store.occurrences("mara", folder)).msg_id

  defp cur_files(root, dir_rel) do
    case File.ls(Path.join([root, "sources", "mail", "mara", "maildir", dir_rel, "cur"])) do
      {:ok, files} -> Enum.sort(files)
      {:error, _} -> []
    end
  end

  defp dir_of(folder), do: elem(Store.get_sync_state("mara", folder), 1).dir

  defp manifest_path(root, id),
    do: Path.join([root, "sources", "mail", "mara", "spool", "#{id}.manifest.yaml"])

  # ==========================================================================
  # Contract 2 — native move ladder + confirmation
  # ==========================================================================

  describe "generic native move" do
    test "moves a message INBOX→Archive: server move, local relocation, dest UID", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_folder(name, "Archive")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root)

      msg_id = msg_id_in("INBOX")
      c = ctx(name, root)

      assert [%{"op" => 0, "result" => "ok"}] =
               OpsExecutor.apply_ops(
                 c,
                 [%{op: :move, msg_id: msg_id, from: "INBOX", to: "Archive"}],
                 "test"
               )

      # Server: gone from INBOX, present in Archive.
      assert ModelMailTransport.messages(name, "INBOX") == []
      assert [%{raw: @raw_a}] = ModelMailTransport.messages(name, "Archive")

      # Local: relocated (INBOX cur empty, Archive cur has the file, U= dest uid).
      assert cur_files(root, dir_of("INBOX")) == []
      [archived] = Store.occurrences("mara", "Archive")
      assert archived.msg_id == msg_id
      assert [file] = cur_files(root, dir_of("Archive"))
      assert {:ok, %{uid: dest_uid}} = Maildir.parse_filename(file)
      assert dest_uid == archived.uid

      # Ledger op resolved (no longer active).
      assert Store.pending_ops("mara") == []
    end

    test "an unknown-folder destination is rejected per-op, nothing moved", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root)

      msg_id = msg_id_in("INBOX")
      c = ctx(name, root)

      assert [%{"op" => 0, "result" => "rejected", "reason" => reason}] =
               OpsExecutor.apply_ops(
                 c,
                 [%{op: :move, msg_id: msg_id, from: "INBOX", to: "Nowhere"}],
                 "test"
               )

      assert reason =~ "unknown destination"
      assert [%{raw: @raw_a}] = ModelMailTransport.messages(name, "INBOX")
    end
  end

  # ==========================================================================
  # Contract 6 — recovery of a crashed-before-execution (pending) move
  # ==========================================================================

  describe "recover pending move" do
    test "a move enqueued but never executed (pending) is executed fresh on recover", %{
      root: root
    } do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_folder(name, "Archive")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root)
      msg_id = msg_id_in("INBOX")

      c = ctx(name, root)

      # Enqueue only (durable row + manifest) — simulate a crash before execute.
      {:ok, op_row} =
        OpsExecutor.enqueue_move(
          c,
          %{op: :move, msg_id: msg_id, from: "INBOX", to: "Archive"},
          "test"
        )

      assert op_row.state == "pending"
      assert ModelMailTransport.messages(name, "Archive") == []

      # Boot recovery re-executes it fresh (verification + ladder).
      OpsExecutor.recover(c)

      assert ModelMailTransport.messages(name, "INBOX") == []
      assert length(ModelMailTransport.messages(name, "Archive")) == 1
      assert Store.pending_ops("mara") == []
    end
  end

  # ==========================================================================
  # M2 — needs_review moves are re-reconciled (manifests don't leak)
  # ==========================================================================

  describe "recover needs_review move (M2)" do
    # A move whose COPY fails outright lands in needs_review with the source
    # untouched and its manifest intact (no destination was ever confirmed).
    defp stuck_needs_review_move!(name, root) do
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_folder(name, "Archive")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root)
      msg_id = msg_id_in("INBOX")

      c = ctx(name, root)
      ModelMailTransport.inject(name, {:fail, :uid_copy, :boom})

      assert [%{"result" => "needs_review"}] =
               OpsExecutor.apply_ops(
                 c,
                 [%{op: :move, msg_id: msg_id, from: "INBOX", to: "Archive"}],
                 "test"
               )

      [row] = Store.pending_ops("mara")
      assert row.state == "needs_review"
      manifest = manifest_path(root, row.id)
      assert File.exists?(manifest)
      # Non-destructive so far: the source occurrence is still on the server.
      assert length(ModelMailTransport.messages(name, "INBOX")) == 1
      assert ModelMailTransport.messages(name, "Archive") == []

      {c, manifest}
    end

    test "a needs_review move whose destination becomes provable resolves; manifest removed", %{
      root: root
    } do
      name = start_model!(capabilities: [:condstore, :uidplus])
      {c, manifest} = stuck_needs_review_move!(name, root)

      # The message lands in Archive out-of-band (a retry or another client).
      ModelMailTransport.put_message(name, "Archive", @raw_a, internal_date: recent_date())

      # Next pass's recovery: confirm-first, proves exactly one destination with
      # the source still present → completes (purges the proven-duplicate
      # source) and cleans up the manifest.
      OpsExecutor.recover(c)

      assert Store.pending_ops("mara") == []
      refute File.exists?(manifest)
      assert ModelMailTransport.messages(name, "INBOX") == []
      assert length(ModelMailTransport.messages(name, "Archive")) == 1
      assert [_file] = cur_files(root, dir_of("Archive"))
    end

    # N1: the reconcile purge is gated by execution-time verification exactly
    # like a fresh ladder. A source UIDVALIDITY reset recycles uids, so the
    # recorded uid may now be an UNRELATED message — purging it would expunge
    # the wrong mail permanently. The companion case (uidvalidity + fingerprint
    # both match → purge proceeds) is pinned by the "destination becomes
    # provable" test above.
    test "a source UIDVALIDITY reset that recycled the uid parks source_reset; the unrelated message is never expunged",
         %{root: root} do
      name = start_model!(capabilities: [:condstore, :uidplus])
      {c, manifest} = stuck_needs_review_move!(name, root)

      # Out-of-band: the move's message lands in Archive (destination becomes
      # provable) and leaves INBOX; a DIFFERENT message arrives; INBOX resets
      # its UIDVALIDITY, renumbering that unrelated message onto the op's
      # recorded uid 1.
      ModelMailTransport.put_message(name, "Archive", @raw_a, internal_date: recent_date())
      ModelMailTransport.delete_message(name, "INBOX", 1)
      ModelMailTransport.put_message(name, "INBOX", @raw_b, internal_date: recent_date())
      ModelMailTransport.reset_uidvalidity(name, "INBOX")
      assert [%{uid: 1, raw: @raw_b}] = ModelMailTransport.messages(name, "INBOX")

      OpsExecutor.recover(c)

      # The unrelated message survives — no mark-deleted, no expunge.
      assert [%{raw: @raw_b, flags: flags}] = ModelMailTransport.messages(name, "INBOX")
      refute "\\Deleted" in flags

      # The row parks needs_review with the mismatch reason; manifest intact
      # so the next pass can retry proving.
      assert [%{state: "needs_review", error: "source_reset"}] = Store.pending_ops("mara")
      assert File.exists?(manifest)
    end

    test "a needs_review move that stays unprovable remains needs_review; manifest intact, source untouched",
         %{root: root} do
      name = start_model!(capabilities: [:condstore, :uidplus])
      {c, manifest} = stuck_needs_review_move!(name, root)

      # The destination never received the message; recovery can't prove it.
      OpsExecutor.recover(c)

      assert [still] = Store.pending_ops("mara")
      assert still.state == "needs_review"
      assert File.exists?(manifest)
      # No destructive step: the source occurrence is untouched.
      assert length(ModelMailTransport.messages(name, "INBOX")) == 1
      assert ModelMailTransport.messages(name, "Archive") == []
    end
  end

  # ==========================================================================
  # Contract 1/7 — execution-time verification / conflict (server wins)
  # ==========================================================================

  describe "execution-time verification" do
    test "UIDVALIDITY reset between mirror and execute → rejected server_changed, no move", %{
      root: root
    } do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_folder(name, "Archive")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root)
      msg_id = msg_id_in("INBOX")

      # Server-side reset AFTER the local mirror captured the old uidvalidity.
      ModelMailTransport.reset_uidvalidity(name, "INBOX")

      c = ctx(name, root)

      assert [%{"result" => "rejected", "reason" => "server_changed"}] =
               OpsExecutor.apply_ops(
                 c,
                 [%{op: :move, msg_id: msg_id, from: "INBOX", to: "Archive"}],
                 "test"
               )

      # No move issued: message still in INBOX, Archive empty.
      assert length(ModelMailTransport.messages(name, "INBOX")) == 1
      assert ModelMailTransport.messages(name, "Archive") == []
    end

    test "server removed the target since last pull → rejected server_changed", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_folder(name, "Archive")
      uid = ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root)
      msg_id = msg_id_in("INBOX")

      # The server drops the message (another client expunged it).
      ModelMailTransport.delete_message(name, "INBOX", uid)

      c = ctx(name, root)

      assert [%{"result" => "rejected", "reason" => "server_changed"}] =
               OpsExecutor.apply_ops(
                 c,
                 [%{op: :move, msg_id: msg_id, from: "INBOX", to: "Archive"}],
                 "test"
               )

      assert ModelMailTransport.messages(name, "Archive") == []
    end
  end

  # ==========================================================================
  # Contract 2 — COPY ladder (no native MOVE) + lost-response reconciliation
  # ==========================================================================

  describe "copy ladder (no MOVE capability)" do
    defp no_move_model!, do: start_model!(capabilities: [:condstore, :uidplus])

    test "COPY → confirm → mark-deleted → expunge, moved once, source gone", %{root: root} do
      name = no_move_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_folder(name, "Archive")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root)
      msg_id = msg_id_in("INBOX")

      c = ctx(name, root)

      assert [%{"result" => "ok"}] =
               OpsExecutor.apply_ops(
                 c,
                 [%{op: :move, msg_id: msg_id, from: "INBOX", to: "Archive"}],
                 "test"
               )

      assert ModelMailTransport.messages(name, "INBOX") == []
      assert [%{raw: @raw_a}] = ModelMailTransport.messages(name, "Archive")
      # No duplicate in Archive.
      assert length(ModelMailTransport.messages(name, "Archive")) == 1
    end

    test "lost COPY response reconciles to exactly one dest, no dup, source not prematurely deleted",
         %{root: root} do
      name = no_move_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_folder(name, "Archive")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root)
      msg_id = msg_id_in("INBOX")

      # The COPY reaches the server (state mutates) but the response is lost.
      ModelMailTransport.inject(name, {:lost_response, :uid_copy})

      c = ctx(name, root)

      [%{"result" => result}] =
        OpsExecutor.apply_ops(
          c,
          [%{op: :move, msg_id: msg_id, from: "INBOX", to: "Archive"}],
          "test"
        )

      assert result in ["ok", "needs_review"]

      # Recovery (belt-and-suspenders, idempotent): reconcile in-flight moves.
      OpsExecutor.recover(c)

      # Exactly one copy in Archive, source removed, no duplicate.
      assert [%{raw: @raw_a}] = ModelMailTransport.messages(name, "Archive")
      assert ModelMailTransport.messages(name, "INBOX") == []
      assert Store.pending_ops("mara") == []
    end
  end

  # ==========================================================================
  # Contract 3 — write-through (excluded destination)
  # ==========================================================================

  describe "write-through destination" do
    test "move into an excluded archive removes the local occurrence, folder stays unmirrored", %{
      root: root
    } do
      s = settings(%{sync: %{settings().sync | exclude_folders: ["Archive"]}})
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_folder(name, "Archive")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root, s)
      msg_id = msg_id_in("INBOX")

      c = ctx(name, root, settings: s)

      assert [%{"result" => "ok"}] =
               OpsExecutor.apply_ops(
                 c,
                 [%{op: :move, msg_id: msg_id, from: "INBOX", to: "Archive"}],
                 "test"
               )

      # Server move happened.
      assert ModelMailTransport.messages(name, "INBOX") == []
      assert length(ModelMailTransport.messages(name, "Archive")) == 1

      # Local occurrence removed (message left the mirrored set) — Archive never
      # became a local maildir folder.
      assert Store.occurrences("mara", "INBOX") == []
      refute File.dir?(Path.join([root, "sources", "mail", "mara", "maildir", "Archive"]))
    end
  end

  # ==========================================================================
  # Contract 4 — Gmail profile
  # ==========================================================================

  describe "gmail profile" do
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

    test "archive to All Mail proven by X-GM-MSGID membership + source absence; local removed", %{
      root: root
    } do
      name = start_model!(gmail: true)
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root, gmail_settings())
      msg_id = msg_id_in("INBOX")

      c = ctx(name, root, settings: gmail_settings())

      assert [%{"result" => "ok"}] =
               OpsExecutor.apply_ops(
                 c,
                 [%{op: :move, msg_id: msg_id, from: "INBOX", to: "[Gmail]/All Mail"}],
                 "test"
               )

      # INBOX label removed; All Mail membership survives.
      assert ModelMailTransport.messages(name, "INBOX") == []
      assert length(ModelMailTransport.messages(name, "[Gmail]/All Mail")) == 1
      # Local INBOX occurrence removed (archived out of the mirror).
      assert Store.occurrences("mara", "INBOX") == []
    end

    test "lost move response converges via the idempotent postcondition on recover", %{root: root} do
      name = start_model!(gmail: true)
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root, gmail_settings())
      msg_id = msg_id_in("INBOX")

      ModelMailTransport.inject(name, {:lost_response, :uid_move})
      c = ctx(name, root, settings: gmail_settings())

      _ =
        OpsExecutor.apply_ops(
          c,
          [%{op: :move, msg_id: msg_id, from: "INBOX", to: "[Gmail]/All Mail"}],
          "test"
        )

      OpsExecutor.recover(c)

      assert ModelMailTransport.messages(name, "INBOX") == []
      assert Store.pending_ops("mara") == []
    end
  end

  # ==========================================================================
  # Contract 5 — flags
  # ==========================================================================

  describe "flag STORE" do
    test "add/remove pushable flags: STORE applied, local filename + uid map updated", %{
      root: root
    } do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")

      ModelMailTransport.put_message(name, "INBOX", @raw_a,
        flags: ["\\Answered"],
        internal_date: recent_date()
      )

      pull!(name, root)
      msg_id = msg_id_in("INBOX")

      c = ctx(name, root, opid: "aaaaaaaaaaaaaaaaaaaaaaaaaa")

      assert [%{"result" => "ok"}] =
               OpsExecutor.apply_ops(
                 c,
                 [%{op: :flag, msg_id: msg_id, folder: "INBOX", add: ["S", "F"], remove: ["R"]}],
                 "test"
               )

      # Server flags: +Seen +Flagged -Answered.
      [msg] = ModelMailTransport.messages(name, "INBOX")
      assert "\\Seen" in msg.flags
      assert "\\Flagged" in msg.flags
      refute "\\Answered" in msg.flags

      # Local uid map reflects it.
      [occ] = Store.occurrences("mara", "INBOX")
      assert MapSet.equal?(occ.flags, MapSet.new(["S", "F"]))
    end

    test "recycled-UID guard: UIDVALIDITY reset before execution → rejected, no STORE issued", %{
      root: root
    } do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root)
      msg_id = msg_id_in("INBOX")

      ModelMailTransport.reset_uidvalidity(name, "INBOX")
      c = ctx(name, root, opid: "bbbbbbbbbbbbbbbbbbbbbbbbbb")

      assert [%{"result" => "rejected", "reason" => "server_changed"}] =
               OpsExecutor.apply_ops(
                 c,
                 [%{op: :flag, msg_id: msg_id, folder: "INBOX", add: ["S"], remove: []}],
                 "test"
               )

      # No flag change on the server.
      [msg] = ModelMailTransport.messages(name, "INBOX")
      refute "\\Seen" in msg.flags
    end

    test "lost STORE response + concurrent re-flag → recover sees baseline moved → needs_review, server untouched",
         %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      uid = ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root)
      msg_id = msg_id_in("INBOX")

      opid = "cccccccccccccccccccccccccc"
      # Simulate the ops-file claim: the engine-owned copy exists, no result yet.
      done_dir = Path.join([root, "sources", "mail", "mara", "ops", "done"])
      File.mkdir_p!(done_dir)

      File.write!(
        Path.join(done_dir, "#{opid}.yaml"),
        "- op: flag\n  msg_id: #{msg_id}\n  folder: INBOX\n  add: [S]\n  remove: []\n"
      )

      c = ctx(name, root, opid: opid)

      # The STORE reaches the server (Seen applied) but the response is lost.
      ModelMailTransport.inject(name, {:lost_response, :uid_store_flags})

      [%{"result" => _}] =
        OpsExecutor.apply_ops(
          c,
          [%{op: :flag, msg_id: msg_id, folder: "INBOX", add: ["S"], remove: []}],
          "test"
        )

      # A concurrent client moves the baseline in a way that UNSETS our
      # postcondition (it clears Seen, sets Flagged) — so recovery must NOT
      # re-assert Seen over the newer change.
      ModelMailTransport.set_flags(name, "INBOX", uid, ["\\Flagged"])

      before =
        ModelMailTransport.messages(name, "INBOX") |> hd() |> Map.get(:flags) |> Enum.sort()

      # Recovery: refetch flags — baseline moved → needs_review, never an
      # overwriting STORE.
      OpsExecutor.recover(c)

      after_flags =
        ModelMailTransport.messages(name, "INBOX") |> hd() |> Map.get(:flags) |> Enum.sort()

      assert after_flags == before

      # The claimed file now has a result recording needs_review.
      {:ok, doc} = YamlElixir.read_from_file(Path.join(done_dir, "#{opid}.result.yaml"))
      assert [%{"result" => "needs_review"}] = doc["results"]
    end
  end

  # ==========================================================================
  # Contract 8 — RPC path (raw ops, per-op vocabulary)
  # ==========================================================================

  describe "apply_raw_ops (RPC)" do
    test "a malformed raw op rejects only itself; a valid one executes", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_folder(name, "Archive")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      ModelMailTransport.put_message(name, "Archive", @raw_b, internal_date: recent_date())
      pull!(name, root)
      msg_id = msg_id_in("INBOX")

      c = ctx(name, root)

      raw_ops = [
        %{"op" => "teleport", "msg_id" => "x"},
        %{"op" => "move", "msg_id" => msg_id, "from" => "INBOX", "to" => "Archive"}
      ]

      assert [
               %{"op" => 0, "result" => "rejected"},
               %{"op" => 1, "result" => "ok"}
             ] = OpsExecutor.apply_raw_ops(c, raw_ops, "rpc")

      assert ModelMailTransport.messages(name, "INBOX") == []
    end
  end

  # ==========================================================================
  # Task 15 — Push-to-Drafts (append)
  # ==========================================================================

  alias Valea.Mail.DraftFile
  alias Valea.Mail.OpsExecutor

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
    status = Keyword.get(opts, :status, "draft")
    extra = Keyword.get(opts, :extra, "")

    """
    ---
    to: #{to}
    subject: "Re: Kickoff"
    status: #{status}
    #{extra}
    ---
    Hello Alex.
    """
  end

  defp spool_eml(root, id),
    do: Path.join([root, "sources", "mail", "mara", "spool", "#{id}.eml"])

  defp read_draft_status(root, name) do
    {:ok, %{status: status}} =
      DraftFile.parse_and_validate(File.read!(Path.join(drafts_dir(root), name)))

    status
  end

  describe "prepare_push (local claim + snapshot + compose + spool)" do
    test "claims, spools, transitions pending, and CAS-stamps the draft pushing", %{root: root} do
      name = start_model!()
      content = write_draft!(root, "reply.md", draft_body())
      hash = DraftFile.content_hash(content)
      c = ctx(name, root)

      assert {:ok, op} = OpsExecutor.prepare_push(local_ctx(c), "reply.md", hash)
      assert op.state == "pending"
      assert File.exists?(spool_eml(root, op.id))
      assert DraftFile.content_hash(File.read!(spool_eml(root, op.id))) == op.payload_sha256

      # The spool payload is a real MIME with our deterministic push Message-ID.
      payload = File.read!(spool_eml(root, op.id))
      assert payload =~ "Message-ID: <valea.push."
      assert payload =~ "To: alex@example.com"

      # CAS stamped the on-disk draft to pushing (ledger is still authoritative).
      assert read_draft_status(root, "reply.md") == "pushing"
    end

    test "a concurrent double-push creates ONE op; the second sees the existing state", %{
      root: root
    } do
      name = start_model!()
      content = write_draft!(root, "reply.md", draft_body())
      hash = DraftFile.content_hash(content)
      lc = local_ctx(ctx(name, root))

      assert {:ok, _op} = OpsExecutor.prepare_push(lc, "reply.md", hash)
      assert {:duplicate, "pushing"} = OpsExecutor.prepare_push(lc, "reply.md", hash)

      assert [%{kind: "append"}] = Store.pending_ops("mara")
    end

    test "a content_hash mismatch (draft edited since review) rejects, never composes", %{
      root: root
    } do
      name = start_model!()
      write_draft!(root, "reply.md", draft_body())
      stale_hash = DraftFile.content_hash("something the reviewer saw earlier")
      c = ctx(name, root)

      assert {:error, "content_changed"} =
               OpsExecutor.prepare_push(local_ctx(c), "reply.md", stale_hash)

      assert [%{state: "rejected"}] = ops_all("drafts/reply.md")
    end

    test "an agent-forged `status: pushed` with no ledger op rejects status_forged", %{root: root} do
      name = start_model!()
      content = write_draft!(root, "reply.md", draft_body(status: "pushed"))
      hash = DraftFile.content_hash(content)
      c = ctx(name, root)

      assert {:error, "status_forged"} = OpsExecutor.prepare_push(local_ctx(c), "reply.md", hash)
    end

    test "a symlinked draft entry is rejected at the no-follow open, never composed", %{
      root: root
    } do
      name = start_model!()
      File.mkdir_p!(drafts_dir(root))
      outside = Path.join(root, "secret.md")
      File.write!(outside, draft_body())
      File.ln_s!(outside, Path.join(drafts_dir(root), "reply.md"))
      hash = DraftFile.content_hash(draft_body())
      c = ctx(name, root)

      assert {:error, "not_found"} = OpsExecutor.prepare_push(local_ctx(c), "reply.md", hash)
      # No op created — the reject happened before the claim.
      assert ops_all("drafts/reply.md") == []
    end

    test "an IN-TREE symlink to another draft is rejected at the no-follow open", %{root: root} do
      name = start_model!()
      dir = drafts_dir(root)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "real.md"), draft_body())
      # A symlink whose target is contained (another draft) must STILL be
      # refused — the no-follow open runs on the literal `drafts/link.md`.
      File.ln_s!(Path.join(dir, "real.md"), Path.join(dir, "link.md"))
      hash = DraftFile.content_hash(draft_body())
      c = ctx(name, root)

      assert {:error, "not_found"} = OpsExecutor.prepare_push(local_ctx(c), "link.md", hash)
      assert ops_all("drafts/link.md") == []
    end

    # Important #1 (fix wave): the local phase does bang I/O + DB writes that
    # can raise (disk full, `database is locked`); a raise must terminate the
    # claimed op `rejected` and surface a clean error — never propagate.
    test "a spool-write crash terminates the claimed op rejected and returns push_failed", %{
      root: root
    } do
      name = start_model!()
      content = write_draft!(root, "reply.md", draft_body())
      hash = DraftFile.content_hash(content)

      # Sabotage: `spool` exists as a regular FILE, so the fsynced payload
      # write's mkdir_p! raises.
      File.write!(Path.join([root, "sources", "mail", "mara", "spool"]), "not a directory")

      c = ctx(name, root)

      assert {:error, "push_failed"} = OpsExecutor.prepare_push(local_ctx(c), "reply.md", hash)
      # The claimed row was terminated — nothing blocks a retry.
      assert [%{state: "rejected", error: "push_failed"}] = ops_all("drafts/reply.md")
    end

    test "in_reply_to resolves threading headers from the referenced canonical file", %{
      root: root
    } do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      pull!(name, root)
      referenced = msg_id_in("INBOX")

      content = write_draft!(root, "reply.md", draft_body(extra: "in_reply_to: #{referenced}"))
      hash = DraftFile.content_hash(content)
      c = ctx(name, root)

      assert {:ok, op} = OpsExecutor.prepare_push(local_ctx(c), "reply.md", hash)
      payload = File.read!(spool_eml(root, op.id))
      # @raw_a's Message-ID is <alpha@example.com>.
      assert payload =~ "In-Reply-To: <alpha@example.com>"
    end
  end

  describe "execute_append (idempotent APPEND)" do
    defp prepared!(root, name, opts) do
      model = Keyword.get(opts, :model)
      ModelMailTransport.put_folder(model, "Drafts")
      content = write_draft!(root, name, draft_body())
      hash = DraftFile.content_hash(content)
      c = ctx(model, root)
      {:ok, op} = OpsExecutor.prepare_push(local_ctx(c), name, hash)
      {c, op}
    end

    test "appends once, completes, cleans the spool, and stamps the draft pushed", %{root: root} do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      assert :ok = OpsExecutor.execute_append(c, op.id)

      assert [msg] = ModelMailTransport.messages(name, "Drafts")
      assert msg.raw =~ "Message-ID: <valea.push."
      assert "\\Draft" in msg.flags

      assert {:ok, %{state: "complete"}} = Store.op_by_id(op.id)
      refute File.exists?(spool_eml(root, op.id))
      assert read_draft_status(root, "reply.md") == "pushed"
    end

    # Minor #2 (fix wave): a FAILED search is never "not present" — the spec's
    # search-FIRST rule is fail-closed. On an unanswerable search nothing is
    # appended; the op stays `pending` and the next attempt retries the search.
    test "a failed Drafts search never issues a blind APPEND; the op stays pending and retries",
         %{root: root} do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      ModelMailTransport.inject(name, {:fail, :uid_search, :boom})

      assert {:needs_review, "search_failed"} = OpsExecutor.execute_append(c, op.id)
      # NO APPEND was issued (the transport call would have landed a message).
      assert ModelMailTransport.messages(name, "Drafts") == []
      # Parked as still-pending: the next pass retries search-first properly.
      assert {:ok, %{state: "pending"}} = Store.op_by_id(op.id)

      # Fault consumed — the retry searches, finds nothing, appends exactly once.
      assert :ok = OpsExecutor.execute_append(c, op.id)
      assert length(ModelMailTransport.messages(name, "Drafts")) == 1
      assert {:ok, %{state: "complete"}} = Store.op_by_id(op.id)
    end

    test "search-first: a lost APPEND response completes without a duplicate", %{root: root} do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      # The APPEND reaches the server (message lands) but the response is lost.
      ModelMailTransport.inject(name, {:lost_response, :append})

      assert :ok = OpsExecutor.execute_append(c, op.id)
      # Exactly one message in Drafts — reconciliation found it, never re-APPENDed.
      assert length(ModelMailTransport.messages(name, "Drafts")) == 1
      assert {:ok, %{state: "complete"}} = Store.op_by_id(op.id)
    end

    test "a definite refusal reverts the draft to draft and rejects the op", %{root: root} do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      ModelMailTransport.inject(name, {:fail, :append, :mailbox_full})

      assert {:rejected, "append_refused"} = OpsExecutor.execute_append(c, op.id)
      assert ModelMailTransport.messages(name, "Drafts") == []
      assert {:ok, %{state: "rejected"}} = Store.op_by_id(op.id)
      # CAS reverted the pushing stamp back to draft.
      assert read_draft_status(root, "reply.md") == "draft"
    end

    test "a spool payload tamper parks the op in needs_review, never appends", %{root: root} do
      name = start_model!()
      {c, op} = prepared!(root, "reply.md", model: name)

      File.write!(spool_eml(root, op.id), "tampered bytes that don't match the recorded hash")

      assert {:needs_review, "payload_hash_mismatch"} = OpsExecutor.execute_append(c, op.id)
      assert ModelMailTransport.messages(name, "Drafts") == []
      assert {:ok, %{state: "needs_review"}} = Store.op_by_id(op.id)
    end

    test "an appended draft filed out of Drafts before reconciliation is found by the widened search",
         %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_folder(name, "Archive")
      ModelMailTransport.put_folder(name, "Drafts")
      # Pull so Archive is a KNOWN folder the widened search will examine.
      pull!(name, root)

      content = write_draft!(root, "reply.md", draft_body())
      hash = DraftFile.content_hash(content)
      c = ctx(name, root)
      {:ok, op} = OpsExecutor.prepare_push(local_ctx(c), "reply.md", hash)

      # Simulate: the APPEND landed, but a client moved it out of Drafts into
      # Archive before we reconciled, and the op is left `executing`.
      payload = File.read!(spool_eml(root, op.id))
      ModelMailTransport.put_message(name, "Archive", payload)
      Store.transition_op(op.id, "executing")

      assert :ok = OpsExecutor.execute_append(c, op.id)
      assert {:ok, %{state: "complete"}} = Store.op_by_id(op.id)
      # No duplicate landed in Drafts.
      assert ModelMailTransport.messages(name, "Drafts") == []
    end
  end

  describe "recover appends" do
    test "a claimed append with no spool is provably un-transmitted → rejected", %{root: root} do
      name = start_model!()
      content = write_draft!(root, "reply.md", draft_body())
      hash = DraftFile.content_hash(content)

      {:ok, op} =
        Store.create_pending_op(%{
          kind: "append",
          account: "mara",
          origin: "drafts/reply.md",
          target_folder: "Drafts",
          message_id: Valea.Mail.DraftMime.push_message_id("mara", "reply.md", hash),
          msg_id: "reply.md",
          state: "claimed"
        })

      c = ctx(name, root)
      OpsExecutor.recover(c)

      assert {:ok, %{state: "rejected"}} = Store.op_by_id(op.id)
      assert Store.pending_ops("mara") == []
    end

    test "a pending append is executed fresh on recover", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "Drafts")
      content = write_draft!(root, "reply.md", draft_body())
      hash = DraftFile.content_hash(content)
      c = ctx(name, root)
      {:ok, _op} = OpsExecutor.prepare_push(local_ctx(c), "reply.md", hash)

      OpsExecutor.recover(c)

      assert length(ModelMailTransport.messages(name, "Drafts")) == 1
      assert Store.pending_ops("mara") == []
    end
  end

  defp ops_all(origin), do: Store.ops_by_origin("mara", origin)
end
