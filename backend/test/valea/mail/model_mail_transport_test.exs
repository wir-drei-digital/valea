defmodule Valea.Mail.ModelMailTransportTest do
  use ExUnit.Case, async: true

  alias ModelMailTransport, as: M

  # Each test starts its own uniquely-named Agent (async: true, so tests
  # must not share a global default name the way FakeMailTransport does).
  defp start!(opts \\ []) do
    name = :"model_#{System.unique_integer([:positive])}"
    {:ok, _pid} = M.start_link(Keyword.put(opts, :name, name))
    name
  end

  defp connect!(name, opts \\ []) do
    {:ok, conn} =
      M.connect(%{host: "x", port: 993, username: "u"}, "pass", Keyword.put(opts, :name, name))

    conn
  end

  @plain """
  From: Priya Nair <priya@example.com>\r
  To: Mara Lindt <mara@example.com>\r
  Subject: Question\r
  Date: Thu, 09 Jul 2026 06:58:00 +0000\r
  Message-ID: <CAJx1234@mail.example.com>\r
  \r
  Hi Mara.\r
  """

  # -- model round-trip: put/select/search/fetch --------------------------

  describe "model round-trip" do
    test "put_folder + put_message round-trips through connect/select/uid_search/fetch" do
      name = start!()
      M.put_folder(name, "INBOX")
      uid = M.put_message(name, "INBOX", @plain, flags: ["\\Seen"])

      conn = connect!(name)

      assert {:ok, %{uidvalidity: 1, uidnext: 2, highestmodseq: _}} = M.select(conn, "INBOX")
      assert {:ok, [^uid]} = M.uid_search(conn, "ALL")
      assert {:ok, [%{uid: ^uid, size: size}]} = M.uid_fetch_meta(conn, [uid])
      assert size == byte_size(@plain)
      assert {:ok, [%{uid: ^uid, header: header}]} = M.uid_fetch_headers(conn, [uid])
      assert header =~ "Message-ID: <CAJx1234@mail.example.com>"
      expected_raw = @plain
      assert {:ok, ^expected_raw} = M.uid_fetch_full(conn, uid)

      assert {:ok, [%{uid: ^uid, flags: ["\\Seen"], modseq: modseq, gm_msgid: nil}]} =
               M.uid_fetch_flags(conn, "1:*")

      assert is_integer(modseq)
    end

    test "list_folders and create_folder" do
      name = start!()
      conn = connect!(name)

      assert {:ok, []} = M.list_folders(conn)
      assert :ok = M.create_folder(conn, "Work")
      assert {:ok, ["Work"]} = M.list_folders(conn)
      assert {:error, _} = M.create_folder(conn, "Work")
    end

    test "list_folders is fault-eligible (T8: routed through the perform/3 chokepoint)" do
      name = start!()
      conn = connect!(name)

      M.inject(name, {:fail, :list_folders, :closed})
      assert {:error, :closed} = M.list_folders(conn)

      # One-shot: the next call succeeds normally.
      assert {:ok, []} = M.list_folders(conn)
    end

    test "capabilities and supports? reflect the default capability set" do
      name = start!()
      conn = connect!(name)

      assert {:ok, wire_caps} = M.capabilities(conn)
      assert "MOVE" in wire_caps
      assert "UIDPLUS" in wire_caps
      assert "CONDSTORE" in wire_caps
      refute "QRESYNC" in wire_caps
      refute "X-GM-EXT-1" in wire_caps

      assert M.supports?(conn, :condstore)
      assert M.supports?(conn, :move)
      assert M.supports?(conn, :uidplus)
      refute M.supports?(conn, :qresync)
      refute M.supports?(conn, :gmail)
    end

    test "logout always returns :ok" do
      name = start!()
      conn = connect!(name)
      assert :ok = M.logout(conn)
    end
  end

  # -- uid auto-assignment -------------------------------------------------

  describe "uid auto-assignment" do
    test "uids auto-assign from 1 and uidnext advances" do
      name = start!()
      M.put_folder(name, "INBOX")

      uid1 = M.put_message(name, "INBOX", "one")
      uid2 = M.put_message(name, "INBOX", "two")
      uid3 = M.put_message(name, "INBOX", "three")

      assert [uid1, uid2, uid3] == [1, 2, 3]

      conn = connect!(name)
      assert {:ok, %{uidvalidity: 1, uidnext: 4}} = M.select(conn, "INBOX")
    end

    test "messages/2 returns raw/flags/uid for round-trip introspection" do
      name = start!()
      M.put_folder(name, "INBOX")
      uid = M.put_message(name, "INBOX", "hello", flags: ["\\Flagged"])

      assert [%{uid: ^uid, flags: ["\\Flagged"], raw: "hello"}] = M.messages(name, "INBOX")
    end
  end

  # -- reset_uidvalidity ----------------------------------------------------

  describe "reset_uidvalidity" do
    test "bumps uidvalidity and re-uids all messages preserving order" do
      name = start!()
      M.put_folder(name, "INBOX")
      _uid1 = M.put_message(name, "INBOX", "one")
      uid2 = M.put_message(name, "INBOX", "two")
      _uid3 = M.put_message(name, "INBOX", "three")

      # Delete the first message so the remaining uids (2, 3) are
      # non-contiguous before the reset re-uids them from 1.
      M.delete_message(name, "INBOX", 1)
      M.reset_uidvalidity(name, "INBOX")

      msgs = M.messages(name, "INBOX")
      assert Enum.map(msgs, & &1.uid) == [1, 2]
      assert Enum.map(msgs, & &1.raw) == ["two", "three"]

      conn = connect!(name)
      assert {:ok, %{uidvalidity: 2, uidnext: 3}} = M.select(conn, "INBOX")
      refute uid2 == 1
    end
  end

  # -- fault injection ------------------------------------------------------

  describe "fault injection" do
    test "{:lost_response, fun_name} mutates then errors exactly once" do
      name = start!()
      M.put_folder(name, "INBOX")
      M.put_folder(name, "Archive")
      uid = M.put_message(name, "INBOX", "hello")
      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")

      M.inject(name, {:lost_response, :uid_move})

      assert {:error, :closed} = M.uid_move(conn, uid, "Archive")

      # The move DID happen server-side despite the error being reported.
      assert M.messages(name, "INBOX") == []
      assert [%{raw: "hello"}] = M.messages(name, "Archive")

      # The fault is one-shot: a second uid_move (on a fresh message) works.
      uid2 = M.put_message(name, "INBOX", "again")
      assert {:ok, %{dest_uid: _}} = M.uid_move(conn, uid2, "Archive")
    end

    test "{:fail, fun_name, reason} does not mutate and errors once" do
      name = start!()
      M.put_folder(name, "INBOX")
      uid = M.put_message(name, "INBOX", "hello", flags: [])
      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")

      M.inject(name, {:fail, :uid_store_flags, :boom})

      assert {:error, :boom} = M.uid_store_flags(conn, uid, ["\\Seen"], [], [])
      assert [%{flags: []}] = M.messages(name, "INBOX")

      # One-shot: the next call succeeds normally.
      assert {:ok, :applied} = M.uid_store_flags(conn, uid, ["\\Seen"], [], [])
      assert [%{flags: ["\\Seen"]}] = M.messages(name, "INBOX")
    end

    test ":drop_connection errors the very next fault-eligible call" do
      name = start!()
      M.put_folder(name, "INBOX")
      conn = connect!(name)

      M.inject(name, :drop_connection)
      assert {:error, _} = M.select(conn, "INBOX")

      # One-shot: the following call succeeds.
      assert {:ok, _} = M.select(conn, "INBOX")
    end

    test "faults are consumed in order and only fire for their target function" do
      name = start!()
      M.put_folder(name, "INBOX")
      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")

      M.inject(name, {:fail, :uid_search, :first})
      M.inject(name, {:fail, :uid_search, :second})

      assert {:error, :first} = M.uid_search(conn, "ALL")
      assert {:error, :second} = M.uid_search(conn, "ALL")
      assert {:ok, []} = M.uid_search(conn, "ALL")
    end

    test "a fault-injected select failure deselects — a stale prior selection isn't left behind" do
      name = start!()
      M.put_folder(name, "A")
      M.put_folder(name, "B")
      conn = connect!(name)

      assert {:ok, _} = M.select(conn, "A")

      M.inject(name, {:fail, :select, :timeout})
      assert {:error, :timeout} = M.select(conn, "B")

      # select B failed, so NO mailbox is selected now — not still "A".
      assert {:error, :no_mailbox_selected} = M.uid_search(conn, "ALL")
    end
  end

  # -- gmail label mode -----------------------------------------------------

  describe "gmail mode" do
    test "list_folders includes [Gmail]/All Mail and every message appears there" do
      name = start!(model: M.initial_model(gmail: true))
      M.put_folder(name, "INBOX")
      M.put_message(name, "INBOX", "hello")

      conn = connect!(name)
      assert {:ok, folders} = M.list_folders(conn)
      assert "[Gmail]/All Mail" in folders

      assert [%{raw: "hello"}] = M.messages(name, "[Gmail]/All Mail")
    end

    test "move INTO All Mail removes from source only, no new All Mail uid" do
      name = start!(model: M.initial_model(gmail: true))
      M.put_folder(name, "INBOX")
      uid = M.put_message(name, "INBOX", "hello")

      [%{uid: all_mail_uid_before}] = M.messages(name, "[Gmail]/All Mail")

      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")

      assert {:ok, %{dest_uid: dest_uid}} = M.uid_move(conn, uid, "[Gmail]/All Mail")
      assert dest_uid == all_mail_uid_before

      assert M.messages(name, "INBOX") == []
      assert [%{uid: ^all_mail_uid_before}] = M.messages(name, "[Gmail]/All Mail")
    end

    test "gm_msgid is stable across folders for the same raw content" do
      name = start!(model: M.initial_model(gmail: true))
      M.put_folder(name, "INBOX")
      M.put_folder(name, "Work")
      M.put_message(name, "INBOX", "same bytes")
      M.put_message(name, "Work", "same bytes")

      conn = connect!(name)

      {:ok, _} = M.select(conn, "INBOX")
      assert {:ok, [%{gm_msgid: gm_msgid_inbox}]} = M.uid_fetch_flags(conn, "1:*")

      {:ok, _} = M.select(conn, "Work")
      assert {:ok, [%{gm_msgid: gm_msgid_work}]} = M.uid_fetch_flags(conn, "1:*")

      refute is_nil(gm_msgid_inbox)
      assert gm_msgid_inbox == gm_msgid_work

      # And the auto-mirrored All Mail occurrences share it too.
      {:ok, _} = M.select(conn, "[Gmail]/All Mail")
      assert {:ok, all_mail_flags} = M.uid_fetch_flags(conn, "1:*")
      assert Enum.all?(all_mail_flags, &(&1.gm_msgid == gm_msgid_inbox))
    end

    test "moves between ordinary folders keep All Mail membership intact" do
      name = start!(model: M.initial_model(gmail: true))
      M.put_folder(name, "INBOX")
      M.put_folder(name, "Work")
      uid = M.put_message(name, "INBOX", "hello")

      [%{uid: all_mail_uid_before}] = M.messages(name, "[Gmail]/All Mail")

      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")
      assert {:ok, %{dest_uid: _}} = M.uid_move(conn, uid, "Work")

      assert M.messages(name, "INBOX") == []
      assert [%{raw: "hello"}] = M.messages(name, "Work")
      assert [%{uid: ^all_mail_uid_before, raw: "hello"}] = M.messages(name, "[Gmail]/All Mail")
    end

    test "supports?/2 reports :gmail and capabilities/1 includes X-GM-EXT-1 in gmail mode" do
      name = start!(model: M.initial_model(gmail: true))
      conn = connect!(name)

      assert M.supports?(conn, :gmail)
      assert {:ok, wire_caps} = M.capabilities(conn)
      assert "X-GM-EXT-1" in wire_caps
    end

    test "uid_copy INTO All Mail reuses the existing All Mail uid, mints no new one" do
      name = start!(model: M.initial_model(gmail: true))
      M.put_folder(name, "INBOX")
      uid = M.put_message(name, "INBOX", "hello")

      [%{uid: all_mail_uid_before}] = M.messages(name, "[Gmail]/All Mail")

      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")

      assert {:ok, %{dest_uid: dest_uid}} = M.uid_copy(conn, uid, "[Gmail]/All Mail")
      assert dest_uid == all_mail_uid_before

      # Copy (not move): source occurrence survives, AND All Mail still has
      # exactly the one, reused uid — no second occurrence was minted.
      assert [%{raw: "hello"}] = M.messages(name, "INBOX")
      assert [%{uid: ^all_mail_uid_before}] = M.messages(name, "[Gmail]/All Mail")
    end
  end

  # -- uid_search criteria --------------------------------------------------

  describe "uid_search criteria" do
    setup do
      name = start!()
      M.put_folder(name, "INBOX")

      uid_old =
        M.put_message(name, "INBOX", @plain, internal_date: "01-Jan-2020")

      uid_new =
        M.put_message(name, "INBOX", "no message id here", internal_date: "2026-07-17")

      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")

      %{conn: conn, uid_old: uid_old, uid_new: uid_new}
    end

    test "ALL returns every uid", %{conn: conn, uid_old: uid_old, uid_new: uid_new} do
      assert {:ok, uids} = M.uid_search(conn, "ALL")
      assert Enum.sort(uids) == Enum.sort([uid_old, uid_new])
    end

    test "UID n:* returns uids from n upward", %{conn: conn, uid_new: uid_new} do
      assert {:ok, [^uid_new]} = M.uid_search(conn, "UID #{uid_new}:*")
    end

    test "UID n:* where n exceeds every existing uid resolves to the max existing uid (RFC 3501)" do
      name = start!()
      M.put_folder(name, "INBOX")
      uid = M.put_message(name, "INBOX", "hello")
      conn = connect!(name)
      assert {:ok, %{uidnext: 2}} = M.select(conn, "INBOX")

      assert {:ok, [^uid]} = M.uid_search(conn, "UID 5:*")
    end

    test "UID n:* on an empty folder resolves to []" do
      name = start!()
      M.put_folder(name, "INBOX")
      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")

      assert {:ok, []} = M.uid_search(conn, "UID 5:*")
    end

    test "SINCE <rfc3501-date> and SINCE <iso-date> both filter by internal_date",
         %{conn: conn, uid_new: uid_new} do
      assert {:ok, [^uid_new]} = M.uid_search(conn, "SINCE 01-Jul-2026")
      assert {:ok, [^uid_new]} = M.uid_search(conn, "SINCE 2026-07-01")
    end

    test "HEADER Message-ID <id> matches the message carrying that header",
         %{conn: conn, uid_old: uid_old} do
      assert {:ok, [^uid_old]} = M.uid_search(conn, "HEADER Message-ID CAJx1234@mail.example.com")
    end

    test "X-GM-MSGID <id> matches by stable gm_msgid" do
      name = start!(model: M.initial_model(gmail: true))
      M.put_folder(name, "INBOX")
      uid = M.put_message(name, "INBOX", "hello")
      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")

      assert {:ok, [%{gm_msgid: gm_msgid}]} = M.uid_fetch_flags(conn, "1:*")
      assert {:ok, [^uid]} = M.uid_search(conn, "X-GM-MSGID #{gm_msgid}")
    end
  end

  # -- uid_store_flags: the real contract -----------------------------------

  describe "uid_store_flags" do
    setup do
      name = start!()
      M.put_folder(name, "INBOX")
      uid = M.put_message(name, "INBOX", "hello", flags: ["\\Seen", "\\Answered"])
      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")
      %{conn: conn, uid: uid, name: name}
    end

    test "plain add with no unchangedsince applies", %{conn: conn, uid: uid, name: name} do
      assert {:ok, :applied} = M.uid_store_flags(conn, uid, ["\\Flagged"], [], [])
      assert [%{flags: flags}] = M.messages(name, "INBOX")
      assert Enum.sort(flags) == Enum.sort(["\\Seen", "\\Answered", "\\Flagged"])
    end

    test "plain remove with no unchangedsince applies", %{conn: conn, uid: uid, name: name} do
      assert {:ok, :applied} = M.uid_store_flags(conn, uid, [], ["\\Answered"], [])
      assert [%{flags: ["\\Seen"]}] = M.messages(name, "INBOX")
    end

    test "unchangedsince matching current modseq applies", %{conn: conn, uid: uid} do
      assert {:ok, [%{modseq: modseq}]} = M.uid_fetch_flags(conn, "1:*")

      assert {:ok, :applied} =
               M.uid_store_flags(conn, uid, ["\\Flagged"], [], unchangedsince: modseq)
    end

    test "unchangedsince stale after a prior change reports :modified",
         %{conn: conn, uid: uid, name: name} do
      assert {:ok, [%{modseq: stale_modseq}]} = M.uid_fetch_flags(conn, "1:*")
      M.set_flags(name, "INBOX", uid, ["\\Seen"])

      assert {:ok, :modified} =
               M.uid_store_flags(conn, uid, ["\\Flagged"], [], unchangedsince: stale_modseq)

      # A MODIFIED response never applies the requested change.
      assert [%{flags: ["\\Seen"]}] = M.messages(name, "INBOX")
    end

    test "combined add+remove under unchangedsince + base_flags issues one atomic replace",
         %{conn: conn, uid: uid, name: name} do
      assert {:ok, [%{modseq: modseq}]} = M.uid_fetch_flags(conn, "1:*")

      assert {:ok, :applied} =
               M.uid_store_flags(conn, uid, ["\\Flagged"], ["\\Seen"],
                 unchangedsince: modseq,
                 base_flags: ["\\Seen", "\\Answered"]
               )

      assert [%{flags: flags}] = M.messages(name, "INBOX")
      assert Enum.sort(flags) == Enum.sort(["\\Answered", "\\Flagged"])
    end

    test "combined add+remove under unchangedsince WITHOUT base_flags raises, no mutation",
         %{conn: conn, uid: uid, name: name} do
      assert_raise ArgumentError, ~r/base_flags/, fn ->
        M.uid_store_flags(conn, uid, ["\\Flagged"], ["\\Seen"], unchangedsince: 1)
      end

      assert [%{flags: flags}] = M.messages(name, "INBOX")
      assert Enum.sort(flags) == Enum.sort(["\\Seen", "\\Answered"])
    end

    test "atomic replace rejects ALL occurrences of a removed flag, even duplicated across base_flags/add",
         %{conn: conn, uid: uid, name: name} do
      # \\Seen appears in BOTH base_flags and add (e.g. a caller re-asserting
      # a flag it's also asking to have removed) — `remove` must still win
      # completely. Kernel `--` only deletes the FIRST matching occurrence
      # per removed element, so it would leave one stray "\\Seen" behind;
      # reject-all-occurrences semantics (mirroring `ImapClient.replace_flags/3`)
      # strips every occurrence.
      assert {:ok, [%{modseq: modseq}]} = M.uid_fetch_flags(conn, "1:*")

      assert {:ok, :applied} =
               M.uid_store_flags(conn, uid, ["\\Seen"], ["\\Seen"],
                 unchangedsince: modseq,
                 base_flags: ["\\Seen", "\\Answered"]
               )

      assert [%{flags: flags}] = M.messages(name, "INBOX")
      refute "\\Seen" in flags
      assert flags == ["\\Answered"]
    end
  end

  # -- move/copy/mark-deleted/expunge/append primitives ----------------------

  describe "move/copy/expunge/append primitives" do
    test "uid_move (non-gmail) reassigns a uid in dest, leaves source empty" do
      name = start!()
      M.put_folder(name, "INBOX")
      M.put_folder(name, "Archive")
      uid = M.put_message(name, "INBOX", "hello")
      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")

      assert {:ok, %{dest_uid: dest_uid}} = M.uid_move(conn, uid, "Archive")
      assert is_integer(dest_uid)
      assert M.messages(name, "INBOX") == []
      assert [%{uid: ^dest_uid, raw: "hello"}] = M.messages(name, "Archive")
    end

    test "uid_copy duplicates into dest without touching source" do
      name = start!()
      M.put_folder(name, "INBOX")
      M.put_folder(name, "Archive")
      uid = M.put_message(name, "INBOX", "hello")
      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")

      assert {:ok, %{dest_uid: dest_uid}} = M.uid_copy(conn, uid, "Archive")
      assert [%{raw: "hello"}] = M.messages(name, "INBOX")
      assert [%{uid: ^dest_uid, raw: "hello"}] = M.messages(name, "Archive")
    end

    test "uid_mark_deleted then uid_expunge removes the message" do
      name = start!()
      M.put_folder(name, "INBOX")
      uid = M.put_message(name, "INBOX", "hello")
      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")

      assert :ok = M.uid_mark_deleted(conn, uid)
      assert [%{flags: ["\\Deleted"]}] = M.messages(name, "INBOX")

      assert :ok = M.uid_expunge(conn, uid)
      assert M.messages(name, "INBOX") == []
    end

    test "uid_expunge without \\Deleted is a no-op" do
      name = start!()
      M.put_folder(name, "INBOX")
      uid = M.put_message(name, "INBOX", "hello")
      conn = connect!(name)
      {:ok, _} = M.select(conn, "INBOX")

      assert :ok = M.uid_expunge(conn, uid)
      assert [%{raw: "hello"}] = M.messages(name, "INBOX")
    end

    test "append inserts into the named folder and returns dest_uid" do
      name = start!()
      M.put_folder(name, "Drafts")
      conn = connect!(name)

      assert {:ok, %{dest_uid: dest_uid}} = M.append(conn, "Drafts", ["\\Seen"], "raw bytes")
      assert [%{uid: ^dest_uid, raw: "raw bytes", flags: ["\\Seen"]}] = M.messages(name, "Drafts")
    end
  end

  # -- examine is read-only ---------------------------------------------------

  describe "examine" do
    test "examine reports the same info as select without altering state" do
      name = start!()
      M.put_folder(name, "INBOX")
      M.put_message(name, "INBOX", "hello")
      conn = connect!(name)

      assert {:ok, info} = M.examine(conn, "INBOX")
      assert %{uidvalidity: 1, uidnext: 2} = info
      assert [%{raw: "hello"}] = M.messages(name, "INBOX")
    end
  end

  # -- folder manipulation ----------------------------------------------------

  describe "folder manipulation" do
    test "rename_folder is delete+create at the LIST level" do
      name = start!()
      M.put_folder(name, "Old")
      M.put_message(name, "Old", "hello")
      conn = connect!(name)

      M.rename_folder(name, "Old", "New")

      assert {:ok, folders} = M.list_folders(conn)
      assert "New" in folders
      refute "Old" in folders
      assert M.messages(name, "New") == []
    end

    test "delete_message removes a single occurrence" do
      name = start!()
      M.put_folder(name, "INBOX")
      uid1 = M.put_message(name, "INBOX", "one")
      _uid2 = M.put_message(name, "INBOX", "two")

      M.delete_message(name, "INBOX", uid1)

      assert [%{raw: "two"}] = M.messages(name, "INBOX")
    end

    test "set_flags replaces the flags list directly" do
      name = start!()
      M.put_folder(name, "INBOX")
      uid = M.put_message(name, "INBOX", "hello", flags: ["\\Seen"])

      M.set_flags(name, "INBOX", uid, ["\\Flagged", "\\Answered"])

      assert [%{flags: ["\\Flagged", "\\Answered"]}] = M.messages(name, "INBOX")
    end
  end
end
