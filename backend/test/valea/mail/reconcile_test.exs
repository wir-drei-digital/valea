defmodule Valea.Mail.ReconcileTest do
  # async: false — each test starts its own `Valea.Repo` against a fresh
  # sqlite file (mirroring sync_pass_test.exs), so tests must not overlap.
  use ExUnit.Case, async: false

  alias Valea.Mail.Maildir
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Reconcile
  alias Valea.Mail.Settings
  alias Valea.Mail.Store
  alias Valea.Mail.SyncPass

  # -- fixtures ---------------------------------------------------------------

  @raw_x """
  From: Xavier Reyes <xavier@example.com>\r
  To: Mara <mara@example.com>\r
  Subject: XSubject\r
  Date: Wed, 15 Jul 2026 09:00:00 +0000\r
  Message-ID: <x@example.com>\r
  \r
  Body of X.\r
  """

  @raw_y """
  From: Yara Sol <yara@example.com>\r
  To: Mara <mara@example.com>\r
  Subject: YSubject\r
  Date: Wed, 15 Jul 2026 10:00:00 +0000\r
  Message-ID: <y@example.com>\r
  \r
  Body of Y.\r
  """

  # A message with NO Message-ID header at all — the >window-old, Message-ID-
  # less case the reset reconciliation must fingerprint-match rather than
  # mistake for a deletion.
  @raw_q """
  From: Quinn Vale <quinn@example.com>\r
  To: Mara <mara@example.com>\r
  Subject: QSubject\r
  Date: Wed, 15 Jul 2020 08:00:00 +0000\r
  \r
  Body of Q (no message-id).\r
  """

  @raw_m """
  From: Mabel Ito <mabel@example.com>\r
  To: Mara <mara@example.com>\r
  Subject: MSubject\r
  Date: Wed, 15 Jul 2026 11:00:00 +0000\r
  Message-ID: <m@example.com>\r
  \r
  Body of M.\r
  """

  @raw_s """
  From: Sol Park <sol@example.com>\r
  To: Mara <mara@example.com>\r
  Subject: SSubject\r
  Date: Wed, 15 Jul 2026 12:00:00 +0000\r
  Message-ID: <s@example.com>\r
  \r
  Body of S (shared across folders).\r
  """

  # A Message-ID carrying an IMAP-unsafe character (a bare space) — the
  # reset-reconciliation shortcut (`HEADER Message-ID <mid>`) must skip this
  # one rather than interpolate it verbatim into the search criteria string.
  @raw_r """
  From: Rin Cole <rin@example.com>\r
  To: Mara <mara@example.com>\r
  Subject: RSubject\r
  Date: Wed, 15 Jul 2026 13:00:00 +0000\r
  Message-ID: <r id@example.com>\r
  \r
  Body of R (unsafe message-id).\r
  """

  # -- setup ------------------------------------------------------------------

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-reconcile-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(root)

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

  defp excluding(folders) do
    settings(%{
      sync: %{
        window_days: 90,
        interval_minutes: 15,
        max_message_bytes: 26_214_400,
        exclude_folders: folders
      }
    })
  end

  defp maildir_dir(root, account, dir_rel),
    do: Path.join([root, "sources", "mail", account, "maildir", dir_rel])

  defp cur_files(root, account, dir_rel) do
    case File.ls(Path.join(maildir_dir(root, account, dir_rel), "cur")) do
      {:ok, files} -> Enum.sort(files)
      {:error, _} -> []
    end
  end

  defp view_path(root, account, msg_id),
    do: Path.join([root, "sources", "mail", account, "views", "messages", "#{msg_id}.md"])

  defp view_frontmatter(root, account, msg_id) do
    {:ok, bytes} = File.read(view_path(root, account, msg_id))
    {:ok, %{frontmatter: fm}} = MessageFile.parse(bytes)
    fm
  end

  defp msg_id_of(account, folder, subject) do
    account
    |> Store.list_messages(folder)
    |> Enum.find(&(&1.subject == subject))
    |> case do
      nil -> nil
      row -> {row.msg_id, row.uid}
    end
  end

  defp recent_date, do: Date.add(Date.utc_today(), -2)
  defp old_date, do: Date.add(Date.utc_today(), -365)

  # ==========================================================================
  # (a) reset with a server-deleted message: stale local occurrence removed
  #     ONLY after complete reconciliation; shared view GC'd when last.
  # ==========================================================================

  test "(a) reset drops a server-deleted occurrence and GCs its view when last", %{root: root} do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Work")
    ModelMailTransport.put_message(name, "Work", @raw_x, internal_date: recent_date())
    ModelMailTransport.put_message(name, "Work", @raw_y, internal_date: recent_date())

    assert {:ok, %{new_messages: 2}} = run(name, root)
    assert length(Store.occurrences("mara", "Work")) == 2
    {x_msg_id, x_uid} = msg_id_of("mara", "Work", "XSubject")
    {y_msg_id, _y_uid} = msg_id_of("mara", "Work", "YSubject")
    assert File.exists?(view_path(root, "mara", x_msg_id))
    assert File.exists?(view_path(root, "mara", y_msg_id))

    # Server deletes X, THEN the folder's UIDVALIDITY resets (Y renumbers to 1).
    ModelMailTransport.delete_message(name, "Work", x_uid)
    ModelMailTransport.reset_uidvalidity(name, "Work")

    assert {:ok, %{notices: notices}} = run(name, root)
    assert Enum.any?(notices, &(&1 =~ "Work" and &1 =~ "reconciled"))

    # Only Y survives, re-bound to its new uid; X (its file, rows, and — as its
    # last occurrence — its view) is gone.
    remaining = Store.occurrences("mara", "Work")
    assert [y] = remaining
    assert y.msg_id == y_msg_id
    assert y.uid == 1
    assert y.uidvalidity == 2

    assert cur_files(root, "mara", "Work") ==
             [Maildir.encode_filename(y_msg_id, 1, MapSet.new())]

    refute File.exists?(view_path(root, "mara", x_msg_id))
    assert File.exists?(view_path(root, "mara", y_msg_id))
    assert Store.list_messages("mara", "Work") |> Enum.map(& &1.uid) == [1]
  end

  # ==========================================================================
  # (b) a >window-old, Message-ID-less, still-present message re-binds across
  #     the reset (new uid, file renamed to new U=), NOT deleted.
  # ==========================================================================

  test "(b) an old Message-ID-less message re-binds by fingerprint, not deleted", %{root: root} do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Work")

    # First pass over an empty Work sets its watermark to 0.
    assert {:ok, %{new_messages: 0}} = run(name, root)

    # X (in-window, has a Message-ID) and Q (>window-old, Message-ID-less) both
    # land via incremental discovery (UID above the watermark, date-independent).
    _x_uid = ModelMailTransport.put_message(name, "Work", @raw_x, internal_date: recent_date())
    _q_uid = ModelMailTransport.put_message(name, "Work", @raw_q, internal_date: old_date())

    assert {:ok, %{new_messages: 2}} = run(name, root)
    {q_msg_id, q_old_uid} = msg_id_of("mara", "Work", "QSubject")
    assert q_old_uid == 2

    # Delete X, then reset — Q renumbers from uid 2 to uid 1.
    {_x_msg_id, x_uid} = msg_id_of("mara", "Work", "XSubject")
    ModelMailTransport.delete_message(name, "Work", x_uid)
    ModelMailTransport.reset_uidvalidity(name, "Work")

    assert {:ok, _} = run(name, root)

    # Q survived the reset: re-bound to its new uid, file renamed, NOT deleted.
    assert [q] = Store.occurrences("mara", "Work")
    assert q.msg_id == q_msg_id
    assert q.uid == 1
    assert q.uidvalidity == 2
    assert cur_files(root, "mara", "Work") == [Maildir.encode_filename(q_msg_id, 1, MapSet.new())]
    assert File.exists?(view_path(root, "mara", q_msg_id))
  end

  # ==========================================================================
  # (h) a Message-ID carrying an IMAP-unsafe character (a bare space) must
  #     never reach the "HEADER Message-ID <mid>" shortcut verbatim — a real
  #     server would return BAD for a malformed search and abort the whole
  #     reconciliation plan. The shortcut is only ever an optimization: with
  #     it skipped, the existing full fingerprint scan still resolves the
  #     occurrence correctly.
  # ==========================================================================

  test "(h) a Message-ID with an unsafe character still reconciles via fingerprint scan", %{
    root: root
  } do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Work")
    ModelMailTransport.put_message(name, "Work", @raw_x, internal_date: recent_date())
    ModelMailTransport.put_message(name, "Work", @raw_r, internal_date: recent_date())

    assert {:ok, %{new_messages: 2}} = run(name, root)
    {r_msg_id, r_old_uid} = msg_id_of("mara", "Work", "RSubject")
    assert r_old_uid == 2

    # Delete X, then reset — R renumbers from uid 2 to uid 1. No server-side
    # change to R's own content. This fake transport won't itself reject a
    # malformed HEADER search (it does a plain substring match, not real IMAP
    # parsing), so it can't prove the shortcut was skipped by making a bad
    # call fail — what it CAN prove is that reconciliation still completes
    # correctly end to end via the fingerprint fallback, which is what
    # actually matters.
    {_x_msg_id, x_uid} = msg_id_of("mara", "Work", "XSubject")
    ModelMailTransport.delete_message(name, "Work", x_uid)
    ModelMailTransport.reset_uidvalidity(name, "Work")

    assert {:ok, %{notices: notices}} = run(name, root)
    assert Enum.any?(notices, &(&1 =~ "Work" and &1 =~ "reconciled"))

    assert [r] = Store.occurrences("mara", "Work")
    assert r.msg_id == r_msg_id
    assert r.uid == 1
    assert r.uidvalidity == 2
    assert cur_files(root, "mara", "Work") == [Maildir.encode_filename(r_msg_id, 1, MapSet.new())]
    assert File.exists?(view_path(root, "mara", r_msg_id))
  end

  # ==========================================================================
  # (c) reconciliation interrupted mid-way -> nothing removed, retried next pass.
  # ==========================================================================

  test "(c) an interrupted reset reconciliation removes nothing and retries next pass", %{
    root: root
  } do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Work")

    assert {:ok, %{new_messages: 0}} = run(name, root)

    _x_uid = ModelMailTransport.put_message(name, "Work", @raw_x, internal_date: recent_date())
    _q_uid = ModelMailTransport.put_message(name, "Work", @raw_q, internal_date: old_date())
    assert {:ok, %{new_messages: 2}} = run(name, root)

    {x_msg_id, x_uid} = msg_id_of("mara", "Work", "XSubject")
    {q_msg_id, _q_uid} = msg_id_of("mara", "Work", "QSubject")

    # Delete X, reset — Q renumbers to uid 1. On the reconciliation pass a body
    # fetch fails: the complete reconciliation aborts and NOTHING is removed.
    ModelMailTransport.delete_message(name, "Work", x_uid)
    ModelMailTransport.reset_uidvalidity(name, "Work")
    ModelMailTransport.inject(name, {:fail, :uid_fetch_full, :closed})

    assert {:ok, %{notices: notices}} = run(name, root)
    assert Enum.any?(notices, &(&1 =~ "Work" and &1 =~ "deferred"))

    # Both local occurrences are untouched, still bound to the OLD uidvalidity;
    # the watermark/uidvalidity were not advanced.
    occs = Store.occurrences("mara", "Work") |> Enum.sort_by(& &1.uid)
    assert Enum.map(occs, & &1.msg_id) |> Enum.sort() == Enum.sort([x_msg_id, q_msg_id])
    assert Enum.all?(occs, &(&1.uidvalidity == 1))
    {:ok, state} = Store.get_sync_state("mara", "Work")
    assert state.uidvalidity == 1

    # Next pass (no fault) completes: X removed, Q re-bound to uid 1.
    assert {:ok, _} = run(name, root)
    assert [q] = Store.occurrences("mara", "Work")
    assert q.msg_id == q_msg_id
    assert q.uid == 1
    assert q.uidvalidity == 2
    refute File.exists?(view_path(root, "mara", x_msg_id))
  end

  # ==========================================================================
  # (e) mailbox_replaced: engine-visible error, NO local deletion happened.
  # ==========================================================================

  test "(e) an account-wide reset fails closed as :mailbox_replaced with nothing deleted", %{
    root: root
  } do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_message(name, "INBOX", @raw_x, internal_date: recent_date())

    assert {:ok, %{new_messages: 1}} = run(name, root)
    before = Store.occurrences("mara", "INBOX")
    files_before = cur_files(root, "mara", "INBOX")
    {x_msg_id, _uid} = msg_id_of("mara", "INBOX", "XSubject")

    # INBOX itself resetting UIDVALIDITY is an unconditional mailbox replacement.
    ModelMailTransport.reset_uidvalidity(name, "INBOX")

    assert {:error, :mailbox_replaced} = run(name, root)

    # Nothing deleted or re-bound: occurrences, file, and view all intact.
    assert Store.occurrences("mara", "INBOX") == before
    assert cur_files(root, "mara", "INBOX") == files_before
    assert File.exists?(view_path(root, "mara", x_msg_id))
  end

  # ==========================================================================
  # (f) folder lifecycle — hold, don't guess.
  # ==========================================================================

  test "(f) a disappeared (newly-excluded) folder is held with files intact and a notice", %{
    root: root
  } do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Work")
    ModelMailTransport.put_message(name, "Work", @raw_m, internal_date: recent_date())

    assert {:ok, %{new_messages: 1}} = run(name, root)
    {m_msg_id, _uid} = msg_id_of("mara", "Work", "MSubject")
    work_files = cur_files(root, "mara", "Work")
    assert work_files != []

    # Work vanishes from the mirrored set (excluded).
    assert {:ok, %{notices: notices}} = run(name, root, settings: excluding(["Work"]))
    assert Enum.any?(notices, &(&1 =~ "Work" and &1 =~ "held"))

    {:ok, state} = Store.get_sync_state("mara", "Work")
    assert state.held == true
    # Local data untouched: files, index rows, and view all still present.
    assert cur_files(root, "mara", "Work") == work_files
    assert length(Store.occurrences("mara", "Work")) == 1
    assert File.exists?(view_path(root, "mara", m_msg_id))
  end

  test "(f) a partial LIST failure holds nothing", %{root: root} do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Work")
    ModelMailTransport.put_message(name, "Work", @raw_m, internal_date: recent_date())

    assert {:ok, %{new_messages: 1}} = run(name, root)

    ModelMailTransport.inject(name, {:fail, :list_folders, :closed})
    assert {:error, {:list_failed, :closed}} = run(name, root)

    {:ok, state} = Store.get_sync_state("mara", "Work")
    assert state.held == false
  end

  test "(f) a rename holds the old folder while the new one pulls independently", %{root: root} do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Work")
    ModelMailTransport.put_message(name, "Work", @raw_m, internal_date: recent_date())

    assert {:ok, %{new_messages: 1}} = run(name, root)
    work_files = cur_files(root, "mara", "Work")

    # Delete+create at the LIST level: Work disappears, Renamed appears empty.
    ModelMailTransport.rename_folder(name, "Work", "Renamed")
    ModelMailTransport.put_message(name, "Renamed", @raw_s, internal_date: recent_date())

    assert {:ok, %{notices: notices}} = run(name, root)
    assert Enum.any?(notices, &(&1 =~ "Work" and &1 =~ "held"))

    # Old folder held, its data untouched; nothing inferred about where it went.
    {:ok, work_state} = Store.get_sync_state("mara", "Work")
    assert work_state.held == true
    assert cur_files(root, "mara", "Work") == work_files

    # New folder pulled independently as an ordinary first sync.
    {:ok, renamed_state} = Store.get_sync_state("mara", "Renamed")
    assert renamed_state.held == false
    assert length(Store.occurrences("mara", "Renamed")) == 1
    assert msg_id_of("mara", "Renamed", "SSubject") != nil
  end

  test "(f) a reappearing held folder is unheld and reconciles again", %{root: root} do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Work")
    ModelMailTransport.put_message(name, "Work", @raw_m, internal_date: recent_date())

    assert {:ok, _} = run(name, root)
    # Exclude Work -> held.
    assert {:ok, _} = run(name, root, settings: excluding(["Work"]))
    {:ok, held_state} = Store.get_sync_state("mara", "Work")
    assert held_state.held == true

    # Work reappears in the mirrored set -> unheld.
    assert {:ok, _} = run(name, root)
    {:ok, state} = Store.get_sync_state("mara", "Work")
    assert state.held == false
  end

  # ==========================================================================
  # (g) discard_held! removes exactly that folder's local data — only when held.
  # ==========================================================================

  test "(g) discard_held! removes exactly the held folder's data with correct view GC", %{
    root: root
  } do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Work")
    # M lives only in Work; S lives in BOTH folders (a shared view).
    ModelMailTransport.put_message(name, "Work", @raw_m, internal_date: recent_date())
    ModelMailTransport.put_message(name, "INBOX", @raw_s, internal_date: recent_date())
    ModelMailTransport.put_message(name, "Work", @raw_s, internal_date: recent_date())

    assert {:ok, %{new_messages: 3}} = run(name, root)
    {m_msg_id, _} = msg_id_of("mara", "Work", "MSubject")
    {s_msg_id, _} = msg_id_of("mara", "Work", "SSubject")
    work_dir = maildir_dir(root, "mara", "Work")
    assert File.dir?(work_dir)

    # Not held yet -> refuses.
    assert {:error, :not_held} = Reconcile.discard_held!(root, "mara", "Work")

    # Hold Work, then discard.
    :ok = Store.mark_held("mara", "Work", true)
    assert :ok = Reconcile.discard_held!(root, "mara", "Work")

    # Work's maildir dir, uid_map rows, index rows, and sync_state are gone.
    refute File.dir?(work_dir)
    assert Store.occurrences("mara", "Work") == []
    assert Store.list_messages("mara", "Work") == []
    assert Store.get_sync_state("mara", "Work") == {:error, :not_found}

    # M's view GC'd (last occurrence gone); S's view kept (still in INBOX).
    refute File.exists?(view_path(root, "mara", m_msg_id))
    assert File.exists?(view_path(root, "mara", s_msg_id))

    # S's surviving shared view no longer lists the discarded "Work" folder
    # in its `folders:` frontmatter — refreshed from its FULL remaining
    # occurrence set (just INBOX now), not left stale from before the discard.
    assert view_frontmatter(root, "mara", s_msg_id)["folders"] == ["INBOX"]

    # INBOX is untouched.
    assert length(Store.occurrences("mara", "INBOX")) == 1
    assert msg_id_of("mara", "INBOX", "SSubject") != nil
  end

  test "(g) discard_held! on a non-existent or unheld folder returns :not_held", %{root: root} do
    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_message(name, "INBOX", @raw_m, internal_date: recent_date())
    assert {:ok, _} = run(name, root)

    assert {:error, :not_held} = Reconcile.discard_held!(root, "mara", "INBOX")
    assert {:error, :not_held} = Reconcile.discard_held!(root, "mara", "Nonexistent")
  end
end
