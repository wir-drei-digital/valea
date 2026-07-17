defmodule Valea.Mail.IndexTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Valea.Mail.Index
  alias Valea.Mail.Maildir
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Normalizer
  alias Valea.Mail.Store
  alias Valea.Mail.Views

  @fixtures_dir Path.expand("../../fixtures/mail", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  # pool_size: 1 — see store_test.exs for why (avoids a transient
  # "database is locked" at pool startup against a brand-new sqlite file).
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-index-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(root)

    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    # `ignore_module_conflict` avoids a "redefining module" warning: every
    # test recompiles the same migration file against a brand-new sqlite db.
    previous_compiler_options = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous_compiler_options)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{root: root}
  end

  defp maildir_root(root, account), do: Path.join([root, "sources", "mail", account, "maildir"])

  defp setup_folder!(maildir_root, dir_name, imap_name) do
    abs = Path.join(maildir_root, dir_name)
    Maildir.mailbox_dirs(abs)
    Maildir.write_folder_identity!(abs, imap_name)
    abs
  end

  defp views_glob(root, account),
    do: Path.wildcard(Path.join([root, "sources", "mail", account, "views", "messages", "*.md"]))

  describe "rebuild/2" do
    test "one shared-fingerprint message landed in two folders: per-occurrence rows + one view",
         %{root: root} do
      account = "mara"
      mroot = maildir_root(root, account)
      inbox_abs = setup_folder!(mroot, "INBOX", "INBOX")
      archive_abs = setup_folder!(mroot, "Archive", "Archive")

      raw = fixture("plain.eml")
      {:ok, %{msg_id: msg_id}} = Views.land(root, account, raw)

      inbox_filename = Maildir.encode_filename(msg_id, 10, MapSet.new(["S"]))
      archive_filename = Maildir.encode_filename(msg_id, 3, MapSet.new(["F", "S"]))

      Maildir.deliver!(inbox_abs, inbox_filename, raw)
      Maildir.deliver!(archive_abs, archive_filename, raw)

      assert {:ok, 2} = Index.rebuild(root, account)

      # sync_state folder -> dir bindings, backfill reset, watermark unset
      assert {:ok, inbox_state} = Store.get_sync_state(account, "INBOX")
      assert inbox_state.dir == "INBOX"
      assert inbox_state.backfill_complete == false
      assert inbox_state.high_water_uid == nil
      assert inbox_state.uidvalidity == nil

      assert {:ok, %{dir: "Archive", backfill_complete: false}} =
               Store.get_sync_state(account, "Archive")

      # uid_map: one occurrence row per folder, same msg_id, folder-specific
      # uid/flags.
      assert [inbox_occ] = Store.occurrences(account, "INBOX")
      assert inbox_occ.uid == 10
      assert inbox_occ.msg_id == msg_id
      assert MapSet.equal?(inbox_occ.flags, MapSet.new(["S"]))

      assert [archive_occ] = Store.occurrences(account, "Archive")
      assert archive_occ.uid == 3
      assert archive_occ.msg_id == msg_id
      assert MapSet.equal?(archive_occ.flags, MapSet.new(["F", "S"]))

      # mail_messages: one occurrence row per folder, metadata from the
      # SHARED view (never re-derived by re-normalizing the raw bytes).
      assert [inbox_row] = Store.list_messages(account, "INBOX")
      assert inbox_row.msg_id == msg_id
      assert inbox_row.message_id == "<CAJx1234@mail.example.com>"
      assert inbox_row.from_name == "Priya Nair"
      assert inbox_row.from_email == "priya@example.com"
      assert inbox_row.subject == "Question about leadership coaching"
      assert inbox_row.date == "2026-07-09T06:58:00Z"
      assert inbox_row.has_attachments == false
      assert inbox_row.flags == "S"
      assert inbox_row.path == "sources/mail/#{account}/maildir/INBOX/cur/#{inbox_filename}"

      assert [archive_row] = Store.list_messages(account, "Archive")
      assert archive_row.uid == 3
      assert archive_row.msg_id == msg_id
      assert archive_row.flags == "FS"
      assert archive_row.path == "sources/mail/#{account}/maildir/Archive/cur/#{archive_filename}"

      # the two occurrences share ONE view — landing once, not duplicated.
      assert length(views_glob(root, account)) == 1
    end

    test "case-colliding folder names keep distinct dirs via .folder-first binding, any walk order",
         %{root: root} do
      # The on-disk `.folder` identity is authoritative for folder -> dir
      # after a wiped SQLite DB (mail-as-maildir design spec, §Storage
      # layout): each directory declares its OWN identity independently of
      # traversal order, so a case-colliding pair ("Work"/"work", mapped by
      # `Maildir.folder_to_dir/2` to two DISTINCT directories) rebinds
      # correctly regardless of which one `File.ls/1` happens to return
      # first — there is nothing here for a reversed walk order to get
      # backwards.
      account = "mara"
      mroot = maildir_root(root, account)

      dir1 = Maildir.folder_to_dir("Work", MapSet.new())
      taken = MapSet.new([dir1 |> String.downcase() |> :unicode.characters_to_nfc_binary()])
      dir2 = Maildir.folder_to_dir("work", taken)
      refute dir1 == dir2

      setup_folder!(mroot, dir1, "Work")
      setup_folder!(mroot, dir2, "work")

      assert {:ok, 0} = Index.rebuild(root, account)

      assert {:ok, %{dir: ^dir1}} = Store.get_sync_state(account, "Work")
      assert {:ok, %{dir: ^dir2}} = Store.get_sync_state(account, "work")
    end

    test "an occurrence whose view was never landed self-heals via raw fallback; doesn't abort the rest",
         %{root: root} do
      account = "mara"
      mroot = maildir_root(root, account)
      inbox_abs = setup_folder!(mroot, "INBOX", "INBOX")

      raw1 = fixture("plain.eml")
      {:ok, %{msg_id: msg_id1}} = Views.land(root, account, raw1)
      filename1 = Maildir.encode_filename(msg_id1, 1, MapSet.new())
      Maildir.deliver!(inbox_abs, filename1, raw1)

      # A second occurrence whose msg_id has no corresponding
      # views/messages/*.md (never landed, or since GC'd) — the occurrence
      # itself is still real (it undeniably exists on disk) and must still
      # be indexed. The raw-fallback path (Task 6 fix wave, item 3)
      # recovers its real metadata by re-normalizing these raw bytes
      # directly (instead of writing a @blank_meta row), and self-heals by
      # re-landing the view from those same bytes.
      raw2 = fixture("no_message_id.eml")
      {:ok, message2} = Normalizer.normalize(raw2)
      msg_id2 = MessageFile.msg_id(message2, raw2)
      filename2 = Maildir.encode_filename(msg_id2, 2, MapSet.new())
      Maildir.deliver!(inbox_abs, filename2, raw2)

      assert {:ok, 2} = Index.rebuild(root, account)

      rows = account |> then(&Store.list_messages(&1, "INBOX")) |> Enum.sort_by(& &1.uid)
      assert [row1, row2] = rows

      assert row1.msg_id == msg_id1
      assert row1.subject == "Question about leadership coaching"

      assert row2.msg_id == msg_id2
      assert row2.subject == "Quick question, no ID"
      assert row2.from_name == "Priya Nair"
      assert row2.from_email == "priya@example.com"
      # no_message_id.eml genuinely has no Message-ID header — that stays nil.
      assert row2.message_id == nil
      assert row2.has_attachments == false

      # self-healing: a view now exists for msg_id2 too.
      assert File.exists?(Path.join(root, Views.view_rel_path(account, msg_id2)))
    end

    test "the view file for a landed message is deleted: rebuild recovers real metadata AND recreates the view file",
         %{root: root} do
      account = "mara"
      mroot = maildir_root(root, account)
      inbox_abs = setup_folder!(mroot, "INBOX", "INBOX")

      raw = fixture("plain.eml")
      {:ok, %{msg_id: msg_id}} = Views.land(root, account, raw)
      filename = Maildir.encode_filename(msg_id, 1, MapSet.new(["S"]))
      Maildir.deliver!(inbox_abs, filename, raw)

      view_file = Path.join(root, Views.view_rel_path(account, msg_id))
      assert File.exists?(view_file)
      File.rm!(view_file)
      refute File.exists?(view_file)

      assert {:ok, 1} = Index.rebuild(root, account)

      assert [row] = Store.list_messages(account, "INBOX")
      assert row.msg_id == msg_id
      assert row.subject == "Question about leadership coaching"
      assert row.from_name == "Priya Nair"
      assert row.from_email == "priya@example.com"
      assert row.message_id == "<CAJx1234@mail.example.com>"

      assert File.exists?(view_file)
      {:ok, %{frontmatter: fm}} = MessageFile.parse(File.read!(view_file))
      assert fm["folders"] == ["INBOX"]
    end

    test "an unparseable (corrupt) view file also falls back to raw metadata and self-heals",
         %{root: root} do
      account = "mara"
      mroot = maildir_root(root, account)
      inbox_abs = setup_folder!(mroot, "INBOX", "INBOX")

      raw = fixture("plain.eml")
      {:ok, %{msg_id: msg_id}} = Views.land(root, account, raw)
      filename = Maildir.encode_filename(msg_id, 1, MapSet.new())
      Maildir.deliver!(inbox_abs, filename, raw)

      view_file = Path.join(root, Views.view_rel_path(account, msg_id))
      File.write!(view_file, "not frontmatter at all, no leading ---\n")

      assert {:ok, 1} = Index.rebuild(root, account)

      assert [row] = Store.list_messages(account, "INBOX")
      assert row.subject == "Question about leadership coaching"

      {:ok, %{frontmatter: fm}} = MessageFile.parse(File.read!(view_file))
      assert fm["id"] == msg_id
    end

    test "an occurrence with no confirmed UID is skipped, logged, and doesn't abort the rest",
         %{root: root} do
      account = "mara"
      mroot = maildir_root(root, account)
      inbox_abs = setup_folder!(mroot, "INBOX", "INBOX")

      raw = fixture("plain.eml")
      {:ok, %{msg_id: msg_id}} = Views.land(root, account, raw)

      # No `,U=` token — a pre-confirmation state that shouldn't normally
      # be sitting in cur/, but rebuild must degrade gracefully, not crash.
      no_uid_filename = Maildir.encode_filename(msg_id, nil, MapSet.new())
      Maildir.deliver!(inbox_abs, no_uid_filename, raw)

      log =
        capture_log(fn ->
          assert {:ok, 0} = Index.rebuild(root, account)
        end)

      assert log =~ "no confirmed UID"
      assert Store.list_messages(account, "INBOX") == []
    end

    test "rebuild is safe to rerun — re-indexing upserts rather than duplicating", %{root: root} do
      account = "mara"
      mroot = maildir_root(root, account)
      inbox_abs = setup_folder!(mroot, "INBOX", "INBOX")

      raw = fixture("plain.eml")
      {:ok, %{msg_id: msg_id}} = Views.land(root, account, raw)
      filename = Maildir.encode_filename(msg_id, 1, MapSet.new(["S"]))
      Maildir.deliver!(inbox_abs, filename, raw)

      assert {:ok, 1} = Index.rebuild(root, account)
      assert {:ok, 1} = Index.rebuild(root, account)
      assert length(Store.list_messages(account, "INBOX")) == 1
      assert length(Store.occurrences(account, "INBOX")) == 1
    end

    test "returns {:ok, 0} when the account has no maildir tree yet", %{root: root} do
      assert {:ok, 0} = Index.rebuild(root, "never-synced")
    end
  end

  # TEMP v3-bridge: removed in Task 9 — see the moduledoc.
  describe "rebuild/1 (TEMP v3-bridge)" do
    test "is a pure no-op, always {:ok, 0}", %{root: root} do
      account = "mara"
      mroot = maildir_root(root, account)
      inbox_abs = setup_folder!(mroot, "INBOX", "INBOX")

      raw = fixture("plain.eml")
      {:ok, %{msg_id: msg_id}} = Views.land(root, account, raw)
      filename = Maildir.encode_filename(msg_id, 1, MapSet.new())
      Maildir.deliver!(inbox_abs, filename, raw)

      assert {:ok, 0} = Index.rebuild(root)
      assert Store.list_messages(account, "INBOX") == []
    end
  end
end
