defmodule Valea.Mail.SyncPassTest do
  # async: false — each test starts its own `Valea.Repo` against a fresh
  # sqlite file (mirroring index_test.exs), so tests must not overlap.
  use ExUnit.Case, async: false

  alias Valea.Mail.Maildir
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Reconcile
  alias Valea.Mail.Settings
  alias Valea.Mail.Store
  alias Valea.Mail.SyncPass

  # -- fixtures ---------------------------------------------------------------

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

  @raw_big """
  From: Loud Sender <loud@example.com>\r
  To: Mara <mara@example.com>\r
  Subject: Huge\r
  Date: Wed, 15 Jul 2026 11:00:00 +0000\r
  Message-ID: <huge@example.com>\r
  \r
  #{String.duplicate("X", 4000)}\r
  """

  # -- setup ------------------------------------------------------------------

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-syncpass-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(root)

    # pool_size: 1 — see store_test.exs / index_test.exs for why (avoids a
    # transient "database is locked" at pool startup against a fresh file).
    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    previous_compiler_options = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous_compiler_options)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{root: root}
  end

  # -- helpers ----------------------------------------------------------------

  defp start_model!(opts \\ []) do
    name = :"model_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ModelMailTransport.start_link(Keyword.put(opts, :name, name))
    name
  end

  defp settings(overrides \\ %{}) do
    base =
      %Settings{
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

  defp run(name, root, opts \\ []) do
    account = Keyword.get(opts, :account, "mara")
    settings = Keyword.get(opts, :settings, settings())

    SyncPass.run(%{
      root: root,
      account: account,
      settings: settings,
      credential: fn -> "app-password" end,
      transport: ModelMailTransport,
      ops_enabled: false,
      connect_opts: [name: name]
    })
  end

  defp cur_dir(root, account, dir_rel),
    do: Path.join([root, "sources", "mail", account, "maildir", dir_rel, "cur"])

  defp cur_files(root, account, dir_rel) do
    case File.ls(cur_dir(root, account, dir_rel)) do
      {:ok, files} -> Enum.sort(files)
      {:error, _} -> []
    end
  end

  defp view_frontmatter(root, account, msg_id) do
    path = Path.join([root, "sources", "mail", account, "views", "messages", "#{msg_id}.md"])
    {:ok, bytes} = File.read(path)
    {:ok, %{frontmatter: fm}} = MessageFile.parse(bytes)
    fm
  end

  defp recent_date, do: Date.add(Date.utc_today(), -2)
  defp old_date, do: Date.add(Date.utc_today(), -365)

  # ==========================================================================
  # Connect / auth contract (preserved from the Task-6 stub — engine depends
  # on it)
  # ==========================================================================

  describe "connect contract" do
    test "auth failure propagates verbatim", %{root: root} do
      name = start_model!()
      ModelMailTransport.inject(name, {:fail, :connect, :auth_failed})
      assert {:error, :auth_failed} = run(name, root)
    end

    test "any other connect failure propagates verbatim", %{root: root} do
      name = start_model!()
      ModelMailTransport.inject(name, {:fail, :connect, :some_other_reason})
      assert {:error, :some_other_reason} = run(name, root)
    end

    test "the credential closure is called exactly once, at the connect boundary", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")

      test_pid = self()

      SyncPass.run(%{
        root: root,
        account: "mara",
        settings: settings(),
        credential: fn -> send(test_pid, :credential_called) && "app-password" end,
        transport: ModelMailTransport,
        ops_enabled: false,
        connect_opts: [name: name]
      })

      assert_received :credential_called
      refute_received :credential_called
    end
  end

  # ==========================================================================
  # 1. Folder set: LIST minus exclude_folders; new folders allocate + write
  #    .folder + sync_state row; existing bindings reused (identities win)
  # ==========================================================================

  describe "folder set" do
    test "mirrors LIST minus exclude_folders; excluded folder never lands", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_folder(name, "Work")
      ModelMailTransport.put_folder(name, "Junk")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
      ModelMailTransport.put_message(name, "Work", @raw_b, internal_date: recent_date())
      ModelMailTransport.put_message(name, "Junk", @raw_a, internal_date: recent_date())

      assert {:ok, %{new_messages: 2}} =
               run(name, root,
                 settings:
                   settings(%{
                     sync: %{
                       exclude_folders: ["Junk"],
                       window_days: 90,
                       interval_minutes: 15,
                       max_message_bytes: 26_214_400
                     }
                   })
               )

      folders = Store.folders("mara") |> Enum.map(& &1.folder) |> Enum.sort()
      assert folders == ["INBOX", "Work"]

      # .folder identity written for mirrored folders
      assert {:ok, "INBOX"} = Maildir.read_folder_identity(folder_dir(root, "mara", "INBOX"))
      assert {:ok, "Work"} = Maildir.read_folder_identity(folder_dir(root, "mara", "Work"))
      # excluded folder: no maildir dir at all
      refute File.dir?(folder_dir(root, "mara", "Junk"))
    end

    test "reuses the on-disk .folder binding after a SQLite loss (identities win)", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "Work")
      ModelMailTransport.put_message(name, "Work", @raw_a, internal_date: recent_date())

      assert {:ok, %{new_messages: 1}} = run(name, root)
      dir_before = cur_dir(root, "mara", "Work")
      assert File.dir?(dir_before)

      # Simulate an app.sqlite loss: wipe every cached row, keep the maildir
      # tree (with its .folder identity) intact.
      Store.clear_folder("mara", "Work")
      assert Store.occurrences("mara", "Work") == []

      # A fresh pass must reuse the SAME directory via its .folder identity,
      # never mint a duplicate `Work-<hash>`.
      assert {:ok, _} = run(name, root)

      maildir_root = Path.join([root, "sources", "mail", "mara", "maildir"])
      work_dirs = File.ls!(maildir_root) |> Enum.filter(&String.starts_with?(&1, "Work"))
      assert work_dirs == ["Work"]
    end
  end

  # ==========================================================================
  # 2. First sync: watermark := uidnext-1; recent mail backfilled
  # ==========================================================================

  describe "first sync" do
    test "recent in-window mail lands on the first pass; watermark set to uidnext-1", %{
      root: root
    } do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      # recent (in window) + old (out of window)
      recent_uid =
        ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())

      _old_uid = ModelMailTransport.put_message(name, "INBOX", @raw_b, internal_date: old_date())

      assert {:ok, %{new_messages: 1}} = run(name, root)

      # only the recent occurrence landed
      assert [occ] = Store.occurrences("mara", "INBOX")
      assert occ.uid == recent_uid

      {:ok, state} = Store.get_sync_state("mara", "INBOX")
      # uidnext was 3 after two inserts -> watermark 2
      assert state.high_water_uid == 2
      assert state.backfill_complete == true
    end
  end

  # ==========================================================================
  # watermark-init: a folder with only old mail fetches nothing across passes
  # ==========================================================================

  test "only-old-mail folder lands nothing on first or second pass", %{root: root} do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: old_date())

    assert {:ok, %{new_messages: 0}} = run(name, root)
    assert Store.occurrences("mara", "INBOX") == []

    assert {:ok, %{new_messages: 0}} = run(name, root)
    assert Store.occurrences("mara", "INBOX") == []
  end

  # ==========================================================================
  # 3. Incremental: UID above watermark lands regardless of message date
  # ==========================================================================

  test "a new UID above the watermark lands on the next pass even with an out-of-window date", %{
    root: root
  } do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")

    # first pass: empty folder -> watermark 0
    assert {:ok, %{new_messages: 0}} = run(name, root)

    # a brand-new message with an OLD date -> its UID is above the watermark
    new_uid = ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: old_date())

    assert {:ok, %{new_messages: 1}} = run(name, root)
    assert [occ] = Store.occurrences("mara", "INBOX")
    assert occ.uid == new_uid

    {:ok, state} = Store.get_sync_state("mara", "INBOX")
    assert state.high_water_uid == new_uid
  end

  # ==========================================================================
  # 4. Landing an occurrence: file + view + index row + uid_map + refresh;
  #    oversized skipped + counted + recorded as __oversize__
  # ==========================================================================

  describe "landing" do
    test "lands file, view, index row, uid_map, and refreshes the view folders line", %{
      root: root
    } do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")

      ModelMailTransport.put_message(name, "INBOX", @raw_a,
        flags: ["\\Seen"],
        internal_date: recent_date()
      )

      assert {:ok, %{new_messages: 1}} = run(name, root)

      assert [occ] = Store.occurrences("mara", "INBOX")
      assert occ.flags == MapSet.new(["S"])

      expected_file = Maildir.encode_filename(occ.msg_id, occ.uid, MapSet.new(["S"]))
      assert cur_files(root, "mara", "INBOX") == [expected_file]

      # index row
      assert [row] = Store.list_messages("mara", "INBOX")
      assert row.subject == "Alpha"
      assert row.message_id == "<alpha@example.com>"
      assert row.flags == "S"

      # view exists and its folders line reflects the occurrence
      fm = view_frontmatter(root, "mara", occ.msg_id)
      assert fm["folders"] == ["INBOX"]
    end

    test "oversized message is skipped, counted in errors, and recorded as __oversize__", %{
      root: root
    } do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")

      big_uid =
        ModelMailTransport.put_message(name, "INBOX", @raw_big, internal_date: recent_date())

      small = %{
        sync: %{
          window_days: 90,
          interval_minutes: 15,
          max_message_bytes: 200,
          exclude_folders: []
        }
      }

      assert {:ok, %{new_messages: 0, errors: errors}} =
               run(name, root, settings: settings(small))

      assert Enum.any?(errors, &(&1 =~ "oversize"))

      # recorded so it's never re-fetched, but excluded from the index + no file
      assert [occ] = Store.occurrences("mara", "INBOX")
      assert occ.uid == big_uid
      assert occ.msg_id == "__oversize__"
      assert Store.list_messages("mara", "INBOX") == []
      assert cur_files(root, "mara", "INBOX") == []
    end
  end

  # ==========================================================================
  # multi-folder membership: same raw in INBOX + Work -> two occurrences, one
  # view
  # ==========================================================================

  test "the same raw in two folders yields two occurrences but one shared view", %{root: root} do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Work")
    ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
    ModelMailTransport.put_message(name, "Work", @raw_a, internal_date: recent_date())

    assert {:ok, %{new_messages: 2}} = run(name, root)

    inbox = Store.occurrences("mara", "INBOX")
    work = Store.occurrences("mara", "Work")
    assert length(inbox) == 1
    assert length(work) == 1
    msg_id = hd(inbox).msg_id
    assert hd(work).msg_id == msg_id

    # exactly one shared view; its folders line lists both
    views_dir = Path.join([root, "sources", "mail", "mara", "views", "messages"])
    assert length(File.ls!(views_dir)) == 1
    fm = view_frontmatter(root, "mara", msg_id)
    assert fm["folders"] == ["INBOX", "Work"]
  end

  # ==========================================================================
  # 5. Flags pull: server flag change rewrites the maildir suffix + caches
  # ==========================================================================

  test "a server-side flag change renames the maildir file and updates the caches", %{root: root} do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")

    uid =
      ModelMailTransport.put_message(name, "INBOX", @raw_a,
        flags: [],
        internal_date: recent_date()
      )

    assert {:ok, _} = run(name, root)
    [occ] = Store.occurrences("mara", "INBOX")
    assert occ.flags == MapSet.new()
    unseen_file = Maildir.encode_filename(occ.msg_id, uid, MapSet.new())
    assert cur_files(root, "mara", "INBOX") == [unseen_file]

    # server marks it \Seen
    ModelMailTransport.set_flags(name, "INBOX", uid, ["\\Seen"])

    assert {:ok, _} = run(name, root)

    [occ2] = Store.occurrences("mara", "INBOX")
    assert occ2.flags == MapSet.new(["S"])
    seen_file = Maildir.encode_filename(occ.msg_id, uid, MapSet.new(["S"]))
    assert cur_files(root, "mara", "INBOX") == [seen_file]
    assert [row] = Store.list_messages("mara", "INBOX")
    assert row.flags == "S"
  end

  # ==========================================================================
  # 6. Deletions: authoritative UID SEARCH ALL; a vanished UID is removed
  # ==========================================================================

  test "a server-side expunge is mirrored: occurrence, file, index row, and view all removed", %{
    root: root
  } do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    uid_a = ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
    _uid_b = ModelMailTransport.put_message(name, "INBOX", @raw_b, internal_date: recent_date())

    assert {:ok, %{new_messages: 2}} = run(name, root)
    assert length(Store.occurrences("mara", "INBOX")) == 2
    [occ_a] = Enum.filter(Store.occurrences("mara", "INBOX"), &(&1.uid == uid_a))

    # server expunges A
    ModelMailTransport.delete_message(name, "INBOX", uid_a)

    assert {:ok, _} = run(name, root)

    remaining = Store.occurrences("mara", "INBOX")
    assert Enum.map(remaining, & &1.uid) |> Enum.sort() == [uid_a + 1]
    # A's file + index row + shared view gone
    refute Maildir.encode_filename(occ_a.msg_id, uid_a, occ_a.flags) in cur_files(
             root,
             "mara",
             "INBOX"
           )

    assert Store.list_messages("mara", "INBOX") |> Enum.map(& &1.uid) == [uid_a + 1]

    view_a =
      Path.join([root, "sources", "mail", "mara", "views", "messages", "#{occ_a.msg_id}.md"])

    refute File.exists?(view_a)
  end

  test "a FAILED deletion enumeration removes nothing", %{root: root} do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    uid_a = ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())

    assert {:ok, _} = run(name, root)
    assert length(Store.occurrences("mara", "INBOX")) == 1

    # server expunges A, but every UID SEARCH fails this pass. A pass issues
    # two `uid_search` calls when backfill is already complete (incremental
    # discovery, then the authoritative ALL enumeration) — fault BOTH so the
    # authoritative ALL search is guaranteed to fail, which must remove
    # nothing.
    ModelMailTransport.delete_message(name, "INBOX", uid_a)
    ModelMailTransport.inject(name, {:fail, :uid_search, :temporary_failure})
    ModelMailTransport.inject(name, {:fail, :uid_search, :temporary_failure})

    assert {:ok, _} = run(name, root)
    # nothing removed on a failed enumeration
    assert length(Store.occurrences("mara", "INBOX")) == 1
  end

  # ==========================================================================
  # 7. UIDVALIDITY reset (single folder): reconciles via Reconcile.folder_reset
  #    (a whole-mailbox replacement already aborted in pull/1). Full reset-
  #    reconciliation behavior — re-bind, removal, interruption — is covered in
  #    reconcile_test.exs; this asserts the SyncPass wiring re-binds and does not
  #    mailbox_replace.
  # ==========================================================================

  test "a single-folder UIDVALIDITY reset reconciles the still-present message in place", %{
    root: root
  } do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Work")
    ModelMailTransport.put_folder(name, "Archive")
    ModelMailTransport.put_message(name, "Work", @raw_a, internal_date: recent_date())

    assert {:ok, _} = run(name, root)
    assert [occ] = Store.occurrences("mara", "Work")

    # bump Work's UIDVALIDITY (INBOX + Archive stay put, so detect_replacement
    # returns :ok — this is an ordinary per-folder reset, not a replacement)
    ModelMailTransport.reset_uidvalidity(name, "Work")

    assert {:ok, %{notices: notices}} = run(name, root)
    assert Enum.any?(notices, &(&1 =~ "Work" and &1 =~ "reset" and &1 =~ "reconciled"))

    # The still-present message is re-bound, not deleted: same msg_id, new
    # uidvalidity, and its maildir file renamed to the new U= token.
    assert [rebound] = Store.occurrences("mara", "Work")
    assert rebound.msg_id == occ.msg_id
    assert rebound.uidvalidity == 2

    assert cur_files(root, "mara", "Work") ==
             [Maildir.encode_filename(rebound.msg_id, rebound.uid, rebound.flags)]

    # Watermark re-initialized as at first sync (UIDNEXT − 1).
    {:ok, state_after} = Store.get_sync_state("mara", "Work")
    assert state_after.uidvalidity == 2
    assert state_after.high_water_uid == rebound.uid
  end

  # ==========================================================================
  # 8. Account-wide reset: INBOX reset -> {:error, :mailbox_replaced}, no
  #    mutation
  # ==========================================================================

  test "an INBOX UIDVALIDITY reset returns :mailbox_replaced before any mutation", %{root: root} do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())

    assert {:ok, _} = run(name, root)
    before = Store.occurrences("mara", "INBOX")
    assert length(before) == 1
    files_before = cur_files(root, "mara", "INBOX")

    ModelMailTransport.reset_uidvalidity(name, "INBOX")

    assert {:error, :mailbox_replaced} = run(name, root)

    # nothing mutated
    assert Store.occurrences("mara", "INBOX") == before
    assert cur_files(root, "mara", "INBOX") == files_before
  end

  # ==========================================================================
  # 9. Damage repair: restore a hand-deleted file; quarantine an unknown file
  # ==========================================================================

  describe "damage repair" do
    test "restores a maildir file deleted out-of-band", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      uid = ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())

      assert {:ok, _} = run(name, root)
      [occ] = Store.occurrences("mara", "INBOX")
      file = Maildir.encode_filename(occ.msg_id, uid, occ.flags)
      assert cur_files(root, "mara", "INBOX") == [file]

      # out-of-band deletion of the local file (message still on the server)
      File.rm!(Path.join(cur_dir(root, "mara", "INBOX"), file))
      assert cur_files(root, "mara", "INBOX") == []

      assert {:ok, %{notices: notices}} = run(name, root)
      # restored from the server
      assert cur_files(root, "mara", "INBOX") == [file]
      assert Enum.any?(notices, &(&1 =~ "restore"))
    end

    test "quarantines an unknown file that appears in cur/", %{root: root} do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())

      assert {:ok, _} = run(name, root)

      # a rogue, unparseable file lands in the engine-owned maildir
      rogue = Path.join(cur_dir(root, "mara", "INBOX"), "not-a-valid-maildir-name.txt")
      File.write!(rogue, "junk")

      assert {:ok, %{notices: notices}} = run(name, root)

      refute File.exists?(rogue)
      assert Enum.any?(notices, &(&1 =~ "quarantine"))

      quarantine_dir = Path.join([root, "sources", "mail", "mara", "quarantine"])
      assert File.dir?(quarantine_dir)
      assert length(File.ls!(quarantine_dir)) == 1
    end

    # Regression: `restore_missing/4` used to call `Views.land/4` (with
    # `msg_id_hint: occ.msg_id`) BEFORE checking whether the re-fetched bytes
    # were still the SAME content this uid held. A content-swap under a
    # stable uid (the hint's stored fingerprint no longer matches) makes
    # `Views.land/4`'s own hint fallback resolve a BRAND NEW msg_id for the
    # new content and write a view + sidecar for it — an orphan, since
    # nothing in `Store` ever comes to reference that id (the occurrence
    # stays under the OLD msg_id, and the mismatch is reported as an error
    # afterwards regardless). Fingerprint-verifying FIRST means a mismatch
    # skips `Views.land/4` entirely: no orphan view ever gets written.
    test "content-swap under a stable UID is verified before landing: no orphan view", %{
      root: root
    } do
      name = start_model!()
      ModelMailTransport.put_folder(name, "INBOX")
      uid = ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())

      assert {:ok, _} = run(name, root)
      [occ] = Store.occurrences("mara", "INBOX")
      msg_id_a = occ.msg_id
      file = Maildir.encode_filename(msg_id_a, uid, occ.flags)
      assert cur_files(root, "mara", "INBOX") == [file]

      views_dir = Path.join([root, "sources", "mail", "mara", "views", "messages"])
      assert File.ls!(views_dir) == ["#{msg_id_a}.md"]

      # Out-of-band deletion of the local file, THEN the server-side content
      # under the SAME uid is swapped for genuinely different bytes.
      # `ModelMailTransport.put_message/4` only ever assigns a FRESH uid, so
      # pinning the same uid to different content means reaching into its
      # Agent state directly (documented shape: `state.folders[folder]
      # .messages[uid].raw`) rather than going through its public API.
      File.rm!(Path.join(cur_dir(root, "mara", "INBOX"), file))

      Agent.update(name, fn state ->
        put_in(state, [:folders, "INBOX", :messages, uid, :raw], @raw_b)
      end)

      assert {:ok, %{errors: errors}} = run(name, root)
      assert Enum.any?(errors, &(&1 =~ "content changed under a stable UID"))

      # Nothing landed: no file delivered under the old name, and no orphan
      # view for the swapped-in content either.
      assert cur_files(root, "mara", "INBOX") == []
      assert File.ls!(views_dir) == ["#{msg_id_a}.md"]
    end
  end

  # ==========================================================================
  # two-account isolation
  # ==========================================================================

  test "two accounts under distinct roots/models stay fully isolated", %{root: root} do
    root_a = Path.join(root, "a")
    root_b = Path.join(root, "b")
    File.mkdir_p!(root_a)
    File.mkdir_p!(root_b)

    name_a = start_model!()
    name_b = start_model!()
    ModelMailTransport.put_folder(name_a, "INBOX")
    ModelMailTransport.put_folder(name_b, "INBOX")
    ModelMailTransport.put_message(name_a, "INBOX", @raw_a, internal_date: recent_date())
    ModelMailTransport.put_message(name_b, "INBOX", @raw_b, internal_date: recent_date())

    assert {:ok, %{new_messages: 1}} = run(name_a, root_a, account: "aaa")
    assert {:ok, %{new_messages: 1}} = run(name_b, root_b, account: "bbb")

    assert [occ_a] = Store.occurrences("aaa", "INBOX")
    assert [occ_b] = Store.occurrences("bbb", "INBOX")
    refute occ_a.msg_id == occ_b.msg_id

    assert Store.occurrences("aaa", "INBOX") |> length() == 1
    assert Store.occurrences("bbb", "INBOX") |> length() == 1
    assert [row_a] = Store.list_messages("aaa", "INBOX")
    assert row_a.subject == "Alpha"
    assert [row_b] = Store.list_messages("bbb", "INBOX")
    assert row_b.subject == "Beta"
  end

  # ==========================================================================
  # Gmail exclusion: All Mail is never mirrored
  # ==========================================================================

  test "gmail All Mail is excluded from the mirror even though every message is auto-mirrored there",
       %{root: root} do
    name = start_model!(model: ModelMailTransport.initial_model(gmail: true))
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())

    gmail_settings =
      settings(%{
        provider: :gmail,
        sync: %{
          window_days: 90,
          interval_minutes: 15,
          max_message_bytes: 26_214_400,
          exclude_folders: Settings.gmail_excludes()
        }
      })

    assert {:ok, %{new_messages: 1}} = run(name, root, settings: gmail_settings)

    folders = Store.folders("mara") |> Enum.map(& &1.folder) |> Enum.sort()
    assert folders == ["INBOX"]
    refute File.dir?(folder_dir(root, "mara", "[Gmail]/All Mail"))
  end

  # ==========================================================================
  # detect_replacement/2 unit cases (pure)
  # ==========================================================================

  describe "Reconcile.detect_replacement/2" do
    test "INBOX resetting is always a replacement" do
      assert Reconcile.detect_replacement(["INBOX"], ["INBOX", "A", "B"]) == :mailbox_replaced
    end

    test "a majority of mirrored folders resetting is a replacement" do
      assert Reconcile.detect_replacement(["A", "B"], ["A", "B", "C"]) == :mailbox_replaced
    end

    test "a single non-INBOX folder resetting is an ordinary per-folder reset" do
      assert Reconcile.detect_replacement(["A"], ["A", "B", "C"]) == :ok
    end

    test "no resets is :ok" do
      assert Reconcile.detect_replacement([], ["A", "B", "C"]) == :ok
    end
  end

  # -- shared path helper -----------------------------------------------------

  defp folder_dir(root, account, dir_rel),
    do: Path.join([root, "sources", "mail", account, "maildir", dir_rel])
end
