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
end
