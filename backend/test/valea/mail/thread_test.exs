defmodule Valea.Mail.ThreadTest do
  @moduledoc """
  Conversation threading (M3 task 10): the `thread_key` derivation
  (`Valea.Mail.Normalizer.thread_key/2`), the single write chokepoint that
  stores it (`Valea.Mail.Store.upsert_index_row/1`), the threaded folder
  listing that collapses by it (`Store.list_threads/4`), the cross-folder
  read (`Store.message_rows_by_thread_key/2`), and `Valea.Mail.Index.rebuild/2`
  as the column's backfill.
  """
  use ExUnit.Case, async: false

  alias Valea.Mail.Index
  alias Valea.Mail.Maildir
  alias Valea.Mail.Normalizer
  alias Valea.Mail.Store
  alias Valea.Mail.Views

  # pool_size: 1 — see store_test.exs for why (avoids a transient
  # "database is locked" at pool startup against a brand-new sqlite file).
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-thread-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(root)

    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrate(:up, all: true)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{root: root}
  end

  # -- the derivation table ---------------------------------------------------

  describe "Normalizer.thread_key/2" do
    test "references head → in_reply_to → message_id → msg_id, in that order" do
      cases = [
        {"the References head wins over in_reply_to and message_id",
         %{
           references: ["<root@x>", "<middle@x>"],
           in_reply_to: "<middle@x>",
           message_id: "<leaf@x>"
         }, "2026-07-01-priya-aabbccdd", "<root@x>"},
        {"references as the space-joined string the Store column holds",
         %{references: "<root@x> <middle@x>", in_reply_to: "<middle@x>", message_id: "<leaf@x>"},
         "2026-07-01-priya-aabbccdd", "<root@x>"},
        {"a whitespace-folded header still yields its first id",
         %{references: "<root@x>\r\n\t<middle@x>\r\n <leaf@x>"}, "2026-07-01-priya-aabbccdd",
         "<root@x>"},
        {"a malformed head is SKIPPED for the first valid entry, not fallen through",
         %{references: "garbage <second@x> <third@x>", in_reply_to: "<not-this@x>"},
         "2026-07-01-priya-aabbccdd", "<second@x>"},
        {"an empty bracket pair is malformed too", %{references: "<> <second@x>"},
         "2026-07-01-priya-aabbccdd", "<second@x>"},
        {"a References with NO valid entry falls through to in_reply_to",
         %{references: "garbage more-garbage", in_reply_to: "<parent@x>", message_id: "<leaf@x>"},
         "2026-07-01-priya-aabbccdd", "<parent@x>"},
        {"no References at all falls through to in_reply_to",
         %{references: [], in_reply_to: "<parent@x>", message_id: "<leaf@x>"},
         "2026-07-01-priya-aabbccdd", "<parent@x>"},
        {"a malformed in_reply_to falls through to message_id",
         %{in_reply_to: "parent-without-brackets", message_id: "<leaf@x>"},
         "2026-07-01-priya-aabbccdd", "<leaf@x>"},
        {"a message with neither threading header threads alone under its own Message-ID",
         %{message_id: "<leaf@x>"}, "2026-07-01-priya-aabbccdd", "<leaf@x>"},
        {"missing everything falls back to the msg_id", %{}, "2026-07-01-priya-aabbccdd",
         "2026-07-01-priya-aabbccdd"},
        {"explicit nils are the same as missing",
         %{references: nil, in_reply_to: nil, message_id: nil}, "2026-07-01-priya-aabbccdd",
         "2026-07-01-priya-aabbccdd"},
        {"a malformed Message-ID falls back to the msg_id",
         %{message_id: "leaf-without-brackets"}, "2026-07-01-priya-aabbccdd",
         "2026-07-01-priya-aabbccdd"},
        {"a self-referencing message threads under its own id, not into a loop",
         %{references: ["<leaf@x>"], in_reply_to: "<leaf@x>", message_id: "<leaf@x>"},
         "2026-07-01-priya-aabbccdd", "<leaf@x>"},
        {"nothing usable anywhere, not even a msg_id, is nil", %{}, nil, nil}
      ]

      for {label, headers, msg_id, expected} <- cases do
        assert Normalizer.thread_key(headers, msg_id) == expected, label
      end
    end

    test "a Message struct is a valid headers map" do
      {:ok, message} = Normalizer.normalize(reply(subject: "Re: Roadmap"))

      assert Normalizer.thread_key(Map.from_struct(message), "fallback") == "<root@example.com>"
    end

    test "invalid UTF-8 in a header is scrubbed, never raised on and never stored raw" do
      key = Normalizer.thread_key(%{message_id: <<"<lea", 0xFF, "f@x>">>}, "fallback")

      assert String.valid?(key)
      assert key =~ "lea"
      assert key =~ "f@x>"
    end

    test "an id longer than an RFC 5322 line is not accepted as a key" do
      oversized = "<" <> String.duplicate("a", 1500) <> "@x>"

      assert Normalizer.thread_key(%{message_id: oversized}, "fallback") == "fallback"
    end
  end

  # -- the write chokepoint ---------------------------------------------------

  describe "Store.upsert_index_row/1 derives thread_key" do
    test "a root and its reply land under the same key" do
      Store.upsert_index_row(row(uid: 1, msg_id: "root", message_id: "<root@x>"))

      Store.upsert_index_row(
        row(
          uid: 2,
          msg_id: "reply",
          message_id: "<reply@x>",
          in_reply_to: "<root@x>",
          references: "<root@x>"
        )
      )

      assert [%{thread_key: "<root@x>"}, %{thread_key: "<root@x>"}] =
               Store.list_messages("mara", "INBOX")
    end

    test "an unrelated message gets its own key" do
      Store.upsert_index_row(row(uid: 1, msg_id: "root", message_id: "<root@x>"))
      Store.upsert_index_row(row(uid: 2, msg_id: "other", message_id: "<other@x>"))

      assert Store.list_messages("mara", "INBOX") |> Enum.map(& &1.thread_key) |> Enum.sort() ==
               ["<other@x>", "<root@x>"]
    end

    test "a thread_key a caller passes is ignored — the derivation is the only writer" do
      Store.upsert_index_row(
        row(uid: 1, msg_id: "root", message_id: "<root@x>", thread_key: "<forged@x>")
      )

      assert [%{thread_key: "<root@x>"}] = Store.list_messages("mara", "INBOX")
    end

    test "re-upserting the same occurrence recomputes the key from the new headers" do
      Store.upsert_index_row(row(uid: 1, msg_id: "m", message_id: "<m@x>"))
      assert [%{thread_key: "<m@x>"}] = Store.list_messages("mara", "INBOX")

      Store.upsert_index_row(
        row(uid: 1, msg_id: "m", message_id: "<m@x>", references: "<root@x>")
      )

      assert [%{thread_key: "<root@x>"}] = Store.list_messages("mara", "INBOX")
    end
  end

  # -- collapse + count -------------------------------------------------------

  describe "Store.list_threads/4" do
    test "one row per thread, the NEWEST representing it, with a count of what it stands for" do
      plant_thread!()

      assert [conversation, standalone] = Store.list_threads("mara", "INBOX")

      assert conversation.msg_id == "reply-2"
      assert conversation.thread_key == "<root@x>"
      assert conversation.thread_count == 3
      assert conversation.subject == "Re: Roadmap again"

      assert standalone.msg_id == "lunch"
      assert standalone.thread_key == "<lunch@x>"
      assert standalone.thread_count == 1
    end

    test "the count is a whole-partition count, not a running one" do
      plant_thread!()

      # The representative is the NEWEST row of its partition; a running
      # COUNT(*) frame (the SQL default when the window carries an ORDER BY)
      # would report 1 for it, not 3.
      assert [%{thread_count: 3} | _] = Store.list_threads("mara", "INBOX")
    end

    test "a folder where every message threads alone lists exactly like a flat listing" do
      Store.upsert_index_row(
        row(uid: 1, msg_id: "a", message_id: "<a@x>", date: "2026-01-01T00:00:00Z")
      )

      Store.upsert_index_row(
        row(uid: 2, msg_id: "b", message_id: "<b@x>", date: "2026-01-02T00:00:00Z")
      )

      threaded = Store.list_threads("mara", "INBOX")

      assert Enum.map(threaded, & &1.msg_id) ==
               Store.list_messages("mara", "INBOX") |> Enum.map(& &1.msg_id)

      assert Enum.map(threaded, & &1.thread_count) == [1, 1]
    end

    test "limit and the before cursor page over CONVERSATIONS, not occurrences" do
      plant_thread!()

      assert [first] = Store.list_threads("mara", "INBOX", 1)
      assert first.msg_id == "reply-2"

      # The cursor is the representative's date, exactly as with
      # `list_messages/4` — the page the caller actually saw.
      assert [second] = Store.list_threads("mara", "INBOX", 1, first.date)
      assert second.msg_id == "lunch"

      assert Store.list_threads("mara", "INBOX", 10, second.date) == []
    end

    test "another folder's occurrences never join this folder's collapse" do
      plant_thread!()

      Store.upsert_index_row(
        row(
          folder: "Archive",
          uid: 9,
          msg_id: "archived-reply",
          message_id: "<archived@x>",
          references: "<root@x>",
          date: "2026-02-01T00:00:00Z"
        )
      )

      assert [%{thread_key: "<root@x>", thread_count: 3} | _] =
               Store.list_threads("mara", "INBOX")

      assert [%{thread_key: "<root@x>", thread_count: 1}] = Store.list_threads("mara", "Archive")
    end

    test "a thread whose root was deleted still holds together under the root's key" do
      plant_thread!()
      Store.delete_index_row("mara", "INBOX", 1)

      assert [%{thread_key: "<root@x>", thread_count: 2, msg_id: "reply-2"} | _] =
               Store.list_threads("mara", "INBOX")
    end

    test "has_attachments comes back as a boolean, not SQLite's integer" do
      Store.upsert_index_row(
        row(uid: 1, msg_id: "with", message_id: "<with@x>", has_attachments: true)
      )

      Store.upsert_index_row(
        row(
          uid: 2,
          msg_id: "without",
          message_id: "<without@x>",
          date: "2026-01-01T00:00:00Z",
          has_attachments: false
        )
      )

      assert [%{has_attachments: true}, %{has_attachments: false}] =
               Store.list_threads("mara", "INBOX")
    end

    test "an empty folder is an empty list, not an error" do
      assert Store.list_threads("mara", "INBOX") == []
    end

    test "two DIFFERENT messages reusing one Message-ID collapse together" do
      # `Message-ID` is sender-controlled and not guaranteed unique (see
      # `Valea.Mail.MessageFile`'s §Fingerprint identity): two distinct
      # messages — distinct bytes, distinct msg_ids, distinct views — can
      # legitimately carry the same one. Threading them together is the
      # honest reading of the header, and the alternative (splitting on
      # something the header does not say) would be a guess.
      Store.upsert_index_row(
        row(uid: 1, msg_id: "first", message_id: "<dup@x>", date: "2026-01-01T00:00:00Z")
      )

      Store.upsert_index_row(
        row(uid: 2, msg_id: "second", message_id: "<dup@x>", date: "2026-01-02T00:00:00Z")
      )

      assert [%{thread_key: "<dup@x>", thread_count: 2, msg_id: "second"}] =
               Store.list_threads("mara", "INBOX")
    end
  end

  # -- the ANY-member unread aggregate ----------------------------------------

  describe "Store.list_threads/4 thread_unread" do
    test "is true when an OLDER member is unread behind a read newest message" do
      # The case the representative row cannot describe, and the whole
      # reason the aggregate exists: `flags` on the returned row is
      # "reply-2"'s, which IS read.
      plant_thread!()

      # Re-upsert of the OLDEST member with its Seen flag dropped — same
      # date, so it stays the oldest and "reply-2" stays the representative.
      Store.upsert_index_row(
        row(
          uid: 1,
          msg_id: "root",
          message_id: "<root@x>",
          date: "2026-01-01T00:00:00Z",
          flags: ""
        )
      )

      assert [conversation, standalone] = Store.list_threads("mara", "INBOX")

      assert conversation.thread_key == "<root@x>"
      assert conversation.msg_id == "reply-2"
      assert conversation.flags == "S"
      assert conversation.thread_unread == true

      # The unrelated single message is untouched by its neighbour's state.
      assert standalone.thread_unread == false
    end

    test "is false when every member of the thread is read" do
      plant_thread!()

      assert [%{thread_count: 3, thread_unread: false} | _] = Store.list_threads("mara", "INBOX")
    end

    test "follows the representative when the thread is one message" do
      Store.upsert_index_row(
        row(uid: 1, msg_id: "read", message_id: "<read@x>", date: "2026-01-01T00:00:00Z")
      )

      Store.upsert_index_row(
        row(
          uid: 2,
          msg_id: "unread",
          message_id: "<unread@x>",
          date: "2026-01-02T00:00:00Z",
          flags: ""
        )
      )

      assert [%{msg_id: "unread", thread_unread: true}, %{msg_id: "read", thread_unread: false}] =
               Store.list_threads("mara", "INBOX")
    end

    test "a NULL flags column reads as unread, not as a missing answer" do
      Store.upsert_index_row(row(uid: 1, msg_id: "m", message_id: "<m@x>", flags: nil))

      # `instr(NULL, 'S')` is NULL, so without the COALESCE the CASE would
      # fall to its ELSE and call an unflagged message read.
      assert [%{thread_unread: true}] = Store.list_threads("mara", "INBOX")
    end

    test "the S test is case-SENSITIVE — a lowercase letter is not Seen" do
      # SQLite's LIKE is case-insensitive for ASCII; `instr` is not. A flag
      # string carrying a lowercase 's' must not count as read.
      Store.upsert_index_row(row(uid: 1, msg_id: "m", message_id: "<m@x>", flags: "s"))

      assert [%{thread_unread: true}] = Store.list_threads("mara", "INBOX")
    end

    test "comes back as a boolean, not SQLite's integer" do
      plant_thread!()

      assert [conversation | _] = Store.list_threads("mara", "INBOX")
      assert is_boolean(conversation.thread_unread)
    end
  end

  # -- cross-folder thread read ------------------------------------------------

  describe "Store.message_rows_by_thread_key/2" do
    test "returns every occurrence of the thread, across folders" do
      plant_thread!()

      Store.upsert_index_row(
        row(
          folder: "Archive",
          uid: 9,
          msg_id: "root",
          message_id: "<root@x>",
          date: "2026-01-01T09:00:00Z"
        )
      )

      rows = Store.message_rows_by_thread_key("mara", "<root@x>")

      assert length(rows) == 4
      assert Enum.map(rows, & &1.folder) |> Enum.sort() == ["Archive", "INBOX", "INBOX", "INBOX"]
    end

    test "an unknown key matches nothing rather than everything" do
      plant_thread!()

      assert Store.message_rows_by_thread_key("mara", "<nope@x>") == []
    end

    test "another account's thread is never visible" do
      plant_thread!()
      Store.upsert_index_row(row(account: "other", uid: 1, msg_id: "o", references: "<root@x>"))

      assert Store.message_rows_by_thread_key("mara", "<root@x>") |> length() == 3
      assert Store.message_rows_by_thread_key("other", "<root@x>") |> length() == 1
    end
  end

  # -- Index.rebuild as the backfill ------------------------------------------

  describe "Index.rebuild/2 backfills thread_key" do
    test "rows written before the column existed get their key on the next rebuild", %{root: root} do
      account = "mara"
      inbox_abs = setup_folder!(root, account, "INBOX", "INBOX")

      root_id = deliver!(root, account, inbox_abs, 1, root_message())
      reply_id = deliver!(root, account, inbox_abs, 2, reply())

      assert {:ok, 2} = Index.rebuild(root, account)

      assert Enum.all?(
               Store.list_messages(account, "INBOX"),
               &(&1.thread_key == "<root@example.com>")
             )

      # Exactly the state an existing store is in the moment the migration
      # adds the column: rows present, every thread_key NULL.
      Valea.Repo.query!("UPDATE mail_messages SET thread_key = NULL", [])
      assert Enum.all?(Store.list_messages(account, "INBOX"), &is_nil(&1.thread_key))

      assert {:ok, 2} = Index.rebuild(root, account)

      assert Store.message_rows_by_thread_key(account, "<root@example.com>")
             |> Enum.map(& &1.msg_id)
             |> Enum.sort() == Enum.sort([root_id, reply_id])

      assert [%{thread_count: 2}] = Store.list_threads(account, "INBOX")
    end

    test "the key is derived from the view file's headers, not re-invented", %{root: root} do
      account = "mara"
      inbox_abs = setup_folder!(root, account, "INBOX", "INBOX")

      deliver!(root, account, inbox_abs, 1, root_message())
      deliver!(root, account, inbox_abs, 2, unrelated())

      assert {:ok, 2} = Index.rebuild(root, account)

      assert Store.list_messages(account, "INBOX") |> Enum.map(& &1.thread_key) |> Enum.sort() ==
               ["<lunch@example.com>", "<root@example.com>"]
    end
  end

  # -- the migration itself ----------------------------------------------------

  describe "20260729000002_mail_thread_keys" do
    test "rolls back and re-applies against a POPULATED table, seeding the last resort" do
      plant_thread!()

      # Down (drops the index, then the column), then up again — the state a
      # long-lived workspace database is in when this migration first runs:
      # `mail_messages` full of rows that predate the column.
      #
      # Targeted at THIS migration's version rather than `step: 1`, which means
      # "the newest migration" and therefore silently rolls back somebody else's
      # work the moment a later migration lands (a `step: 1` here rolled back
      # `20260730000001_create_schedule_tables` instead, and the expected raise
      # never came). `to:` walks down to and including this version — later
      # migrations included, which `migrate(:up, all: true)` then re-applies.
      migrate(:down, to: 20_260_729_000_002)

      assert Valea.Repo.query!("SELECT count(*) FROM mail_messages", []).rows == [[4]]

      assert_raise Exqlite.Error, fn ->
        Valea.Repo.query!("SELECT thread_key FROM mail_messages", [])
      end

      migrate(:up, all: true)

      # Every pre-existing row comes out of the migration threading alone
      # under its own msg_id — coarse, never NULL (a NULL would make the
      # whole folder one bogus conversation, since NULLs partition equal).
      %{rows: rows} = Valea.Repo.query!("SELECT msg_id, thread_key FROM mail_messages", [])
      assert Enum.all?(rows, fn [msg_id, thread_key] -> thread_key == msg_id end)
      assert length(Store.list_threads("mara", "INBOX")) == 4
    end
  end

  # -- fixtures ----------------------------------------------------------------

  # `ignore_module_conflict` avoids a "redefining module" warning: every test
  # recompiles the same migration files against a brand-new sqlite db.
  defp migrate(direction, opts) do
    path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    previous = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, path, direction, opts)
    Code.compiler_options(previous)
  end

  defp row(overrides) do
    Map.merge(
      %{
        account: "mara",
        folder: "INBOX",
        uid: 1,
        msg_id: "m1",
        message_id: nil,
        from_name: "Priya",
        from_email: "priya@example.com",
        subject: "s",
        date: "2026-01-05T00:00:00Z",
        flags: "S",
        has_attachments: false,
        path: "sources/mail/mara/maildir/INBOX/cur/m1",
        in_reply_to: nil,
        references: nil
      },
      Map.new(overrides)
    )
  end

  # A three-message conversation plus one unrelated message, all in INBOX.
  defp plant_thread! do
    Store.upsert_index_row(
      row(
        uid: 1,
        msg_id: "root",
        message_id: "<root@x>",
        subject: "Roadmap",
        date: "2026-01-01T00:00:00Z"
      )
    )

    Store.upsert_index_row(
      row(
        uid: 2,
        msg_id: "reply-1",
        message_id: "<reply-1@x>",
        in_reply_to: "<root@x>",
        references: "<root@x>",
        subject: "Re: Roadmap",
        date: "2026-01-02T00:00:00Z"
      )
    )

    Store.upsert_index_row(
      row(
        uid: 3,
        msg_id: "reply-2",
        message_id: "<reply-2@x>",
        in_reply_to: "<reply-1@x>",
        references: "<root@x> <reply-1@x>",
        subject: "Re: Roadmap again",
        date: "2026-01-03T00:00:00Z"
      )
    )

    # Newer than the whole thread would be if it did not collapse, so a
    # broken collapse shows up as a reordering, not just a longer list.
    Store.upsert_index_row(
      row(
        uid: 4,
        msg_id: "lunch",
        message_id: "<lunch@x>",
        subject: "Lunch",
        date: "2026-01-02T12:00:00Z"
      )
    )
  end

  defp root_message do
    """
    From: Priya Nair <priya@example.com>\r
    Subject: Roadmap\r
    Date: Wed, 01 Jul 2026 09:00:00 +0000\r
    Message-ID: <root@example.com>\r
    \r
    Let us discuss the roadmap.\r
    """
  end

  defp reply(opts \\ []) do
    subject = Keyword.get(opts, :subject, "Re: Roadmap")

    """
    From: Mara Lindt <mara@example.com>\r
    Subject: #{subject}\r
    Date: Thu, 02 Jul 2026 09:00:00 +0000\r
    Message-ID: <reply@example.com>\r
    In-Reply-To: <root@example.com>\r
    References: <root@example.com>\r
    \r
    Sounds good.\r
    """
  end

  defp unrelated do
    """
    From: Sam Okafor <sam@example.net>\r
    Subject: Lunch\r
    Date: Fri, 03 Jul 2026 09:00:00 +0000\r
    Message-ID: <lunch@example.com>\r
    \r
    Bistro tomorrow?\r
    """
  end

  defp setup_folder!(root, account, dir_name, imap_name) do
    abs = Path.join([root, "sources", "mail", account, "maildir", dir_name])
    Maildir.mailbox_dirs(abs)
    Maildir.write_folder_identity!(abs, imap_name)
    abs
  end

  defp deliver!(root, account, folder_abs, uid, raw) do
    {:ok, %{msg_id: msg_id}} = Views.land(root, account, raw)
    Maildir.deliver!(folder_abs, Maildir.encode_filename(msg_id, uid, MapSet.new(), ":"), raw)
    msg_id
  end
end
