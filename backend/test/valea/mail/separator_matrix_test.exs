defmodule Valea.Mail.SeparatorMatrixTest do
  @moduledoc """
  windows-support spec C1's completeness matrix: ONE `;`-separator store
  driven through every stage that writes a maildir filename — deliver, flag
  rename (pull side AND ops side), move, `UIDVALIDITY`-reset reconciliation,
  and crash recovery — asserting that no stage anywhere produces a classic
  `:2,` name.

  The point is coverage of the *encode* seams, not of each stage's own
  semantics (those are pinned by `sync_pass_test.exs`, `ops_executor_test.exs`
  and `reconcile_test.exs`). If a future encode site forgets to thread the
  store separator, the final whole-tree sweep here is what catches it — on
  any host, without needing NTFS.
  """

  # async: false — own `Valea.Repo` against a fresh sqlite file, same as the
  # other mail suites.
  use ExUnit.Case, async: false

  alias Valea.Mail.Account
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

  @raw_c """
  From: Sol Park <sol@example.com>\r
  To: Mara <mara@example.com>\r
  Subject: Gamma\r
  Date: Wed, 15 Jul 2026 11:00:00 +0000\r
  Message-ID: <gamma@example.com>\r
  \r
  Body of gamma.\r
  """

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-sepmatrix-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
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

  # -- factories (same shapes as sync_pass_test / ops_executor_test) --------

  defp start_model!(opts \\ []) do
    name = :"model_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ModelMailTransport.start_link(Keyword.put(opts, :name, name))
    name
  end

  defp settings do
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
  end

  # A store whose `.account` says `;` — exactly what `Valea.Mail.Engine`
  # writes when it claims a slug on Windows.
  defp semicolon_store!(root) do
    :ok =
      Account.write_if_absent!(
        root,
        "mara",
        %{host: "imap.example.test", username: "mara@example.com"},
        ";"
      )

    assert Account.separator(root, "mara") == {:ok, ";"}
  end

  defp pass!(name, root) do
    SyncPass.run(%{
      root: root,
      account: "mara",
      settings: settings(),
      credential: fn -> "app-password" end,
      transport: ModelMailTransport,
      separator: ";",
      connect_opts: [name: name]
    })
  end

  defp ctx(name, root) do
    {:ok, conn} = ModelMailTransport.connect(%{}, "pw", name: name)

    %{
      root: root,
      account: "mara",
      settings: settings(),
      transport: ModelMailTransport,
      conn: conn,
      separator: ";"
    }
  end

  defp maildir_root(root), do: Path.join([root, "sources", "mail", "mara", "maildir"])

  defp dir_of(folder), do: elem(Store.get_sync_state("mara", folder), 1).dir

  defp cur_files(root, folder) do
    case File.ls(Path.join([maildir_root(root), dir_of(folder), "cur"])) do
      {:ok, files} -> Enum.sort(files)
      {:error, _} -> []
    end
  end

  # Every maildir filename anywhere under the account, at any nesting depth.
  defp every_maildir_file(root) do
    root
    |> maildir_root()
    |> Path.join("**/cur/*")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.sort()
  end

  defp msg_id_in(folder), do: hd(Store.occurrences("mara", folder)).msg_id
  defp uid_in(folder), do: hd(Store.occurrences("mara", folder)).uid
  defp recent_date, do: Date.add(Date.utc_today(), -2)

  defp assert_semicolon_only!(files) do
    assert files != [], "expected at least one maildir file to assert on"
    assert Enum.all?(files, &String.contains?(&1, ";2,")), "not all `;2,`: #{inspect(files)}"

    refute Enum.any?(files, &String.contains?(&1, ":2,")),
           "a `:2,` name leaked: #{inspect(files)}"
  end

  # =========================================================================
  # The matrix
  # =========================================================================

  test "deliver -> flag rename -> move -> reconcile -> recovery all write `;` names",
       %{root: root} do
    semicolon_store!(root)

    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Archive")
    ModelMailTransport.put_folder(name, "Work")
    ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
    ModelMailTransport.put_message(name, "INBOX", @raw_b, internal_date: recent_date())
    ModelMailTransport.put_message(name, "Work", @raw_c, internal_date: recent_date())

    # -- 1. deliver (SyncPass landing) --------------------------------------
    assert {:ok, %{new_messages: 3}} = pass!(name, root)
    inbox = cur_files(root, "INBOX")
    assert length(inbox) == 2
    assert_semicolon_only!(inbox)

    # -- 2. flag rename, pull side (server-driven \Seen) --------------------
    a_uid = hd(Enum.sort_by(Store.occurrences("mara", "INBOX"), & &1.uid)).uid
    ModelMailTransport.set_flags(name, "INBOX", a_uid, ["\\Seen"])

    assert {:ok, _} = pass!(name, root)
    seen = cur_files(root, "INBOX")
    assert Enum.any?(seen, &String.ends_with?(&1, ";2,S"))
    assert_semicolon_only!(seen)

    # -- 3. flag rename, ops side (declared flag op) ------------------------
    c = ctx(name, root)
    flagged_msg_id = Enum.find(Store.occurrences("mara", "INBOX"), &(&1.uid == a_uid)).msg_id

    assert [%{"result" => "ok"}] =
             OpsExecutor.apply_ops(
               c,
               [%{op: :flag, msg_id: flagged_msg_id, folder: "INBOX", add: ["F"], remove: []}],
               "test"
             )

    assert Enum.any?(cur_files(root, "INBOX"), &String.ends_with?(&1, ";2,FS"))
    assert_semicolon_only!(cur_files(root, "INBOX"))

    # -- 4. move (OpsExecutor relocate into a new folder dir) ---------------
    moved_msg_id = Enum.find(Store.occurrences("mara", "INBOX"), &(&1.uid != a_uid)).msg_id

    assert [%{"result" => "ok"}] =
             OpsExecutor.apply_ops(
               c,
               [%{op: :move, msg_id: moved_msg_id, from: "INBOX", to: "Archive"}],
               "test"
             )

    assert_semicolon_only!(cur_files(root, "Archive"))

    # -- 5. reconcile (UIDVALIDITY reset re-binds + renames the survivor) ---
    # A NON-INBOX single-folder reset: an INBOX reset would be a whole-mailbox
    # replacement and abort the pass before mutating anything.
    ModelMailTransport.reset_uidvalidity(name, "Work")

    assert {:ok, %{notices: notices}} = pass!(name, root)
    assert Enum.any?(notices, &(&1 =~ "Work" and &1 =~ "reconciled"))
    assert_semicolon_only!(cur_files(root, "Work"))

    # -- 6. recovery (a durable move replayed from its manifest at boot) ----
    recovered_msg_id = msg_id_in("INBOX")
    c2 = ctx(name, root)

    {:ok, op_row} =
      OpsExecutor.enqueue_move(
        c2,
        %{op: :move, msg_id: recovered_msg_id, from: "INBOX", to: "Archive"},
        "test"
      )

    assert op_row.state == "pending"
    OpsExecutor.recover(c2)
    assert Store.pending_ops("mara") == []
    assert cur_files(root, "INBOX") == []
    assert_semicolon_only!(cur_files(root, "Archive"))

    # -- the sweep: nothing, anywhere, in any stage, wrote a `:` name -------
    assert_semicolon_only!(every_maildir_file(root))
  end

  test "recovery's fallback lookup finds a `;` occurrence whose file is gone", %{root: root} do
    semicolon_store!(root)

    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_folder(name, "Archive")
    ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
    assert {:ok, %{new_messages: 1}} = pass!(name, root)

    # Out-of-band damage: the file is gone, so `source_file_path/5` cannot
    # read the name off disk and must ENCODE it — the one path where a
    # mis-threaded separator would silently name a `:` file.
    [file] = cur_files(root, "INBOX")
    File.rm!(Path.join([maildir_root(root), dir_of("INBOX"), "cur", file]))

    c = ctx(name, root)
    msg_id = msg_id_in("INBOX")

    # No source bytes to copy, so the move degrades to dropping the local
    # occurrence — the assertion that matters is that it never resurrects a
    # `:`-named file while doing so.
    assert [%{"result" => result}] =
             OpsExecutor.apply_ops(
               c,
               [%{op: :move, msg_id: msg_id, from: "INBOX", to: "Archive"}],
               "test"
             )

    assert result in ["ok", "needs_review", "rejected"]
    refute Enum.any?(every_maildir_file(root), &String.contains?(&1, ":2,"))
  end

  # =========================================================================
  # Mixed-separator listing (spec C1: `parse_filename/1` is unconditional)
  # =========================================================================

  test "one listing holding BOTH separators parses in full", %{root: root} do
    dir = Path.join(root, "mixed")
    :ok = Maildir.mailbox_dirs(dir)

    classic = Maildir.encode_filename("2026-07-15-alex-4f2a91c3", 1, MapSet.new(["S"]), ":")
    ntfs = Maildir.encode_filename("2026-07-16-blair-9d1e0742", 2, MapSet.new(["F", "S"]), ";")
    :ok = Maildir.deliver!(dir, classic, "classic bytes")
    :ok = Maildir.deliver!(dir, ntfs, "ntfs bytes")

    occurrences = dir |> Maildir.list_occurrences() |> Enum.sort_by(& &1.uid)

    assert [
             %{msg_id: "2026-07-15-alex-4f2a91c3", uid: 1, flags: classic_flags},
             %{msg_id: "2026-07-16-blair-9d1e0742", uid: 2, flags: ntfs_flags}
           ] = occurrences

    assert MapSet.equal?(classic_flags, MapSet.new(["S"]))
    assert MapSet.equal?(ntfs_flags, MapSet.new(["F", "S"]))
  end

  test "a `;`-store indexes a legacy `:`-named file it finds on disk", %{root: root} do
    semicolon_store!(root)

    name = start_model!()
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_message(name, "INBOX", @raw_a, internal_date: recent_date())
    assert {:ok, %{new_messages: 1}} = pass!(name, root)

    # Rewrite the delivered occurrence under the CLASSIC separator, as a
    # store carried over from a `:` host would look, and re-index: the
    # occurrence must still be recognised (never quarantined as unknown).
    cur = Path.join([maildir_root(root), dir_of("INBOX"), "cur"])
    [file] = File.ls!(cur)
    legacy = String.replace(file, ";2,", ":2,")
    File.rename!(Path.join(cur, file), Path.join(cur, legacy))

    uid = uid_in("INBOX")
    {:ok, _count} = Valea.Mail.Index.rebuild(root, "mara")

    assert [%{uid: ^uid}] = Store.occurrences("mara", "INBOX")
    assert File.ls!(cur) == [legacy]
  end
end
