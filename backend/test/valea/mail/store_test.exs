defmodule Valea.Mail.StoreTest do
  use ExUnit.Case, async: false

  alias Valea.Mail.Store

  # Focused unit tests per the task brief: start `Valea.Repo` directly
  # against a tmp `app.sqlite` + run the real migrations, rather than going
  # through the full `Valea.Workspace.Manager` open lifecycle (ICM watcher,
  # runtime, scaffold — none of which `Store` needs).
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-store-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    # pool_size: 1 — a single sequential test process needs no concurrent
    # connections, and it sidesteps a startup race where multiple pool
    # workers open the brand-new sqlite file while the migration is still
    # running its DDL (logs a transient, harmless "database is locked").
    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    # `ignore_module_conflict` avoids a "redefining module" warning: every
    # test recompiles the same migration file against a brand-new sqlite db.
    previous_compiler_options = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous_compiler_options)

    on_exit(fn -> File.rm_rf!(dir) end)

    :ok
  end

  describe "sync_state" do
    test "get_sync_state is :not_found before anything is written" do
      assert {:error, :not_found} = Store.get_sync_state("INBOX")
    end

    test "put_sync_state upserts; a second write for the same folder replaces the watermark" do
      assert :ok = Store.put_sync_state("INBOX", 100, 4711)
      assert {:ok, %{uidvalidity: 100, high_water_uid: 4711}} = Store.get_sync_state("INBOX")

      assert :ok = Store.put_sync_state("INBOX", 100, 4800)
      assert {:ok, %{uidvalidity: 100, high_water_uid: 4800}} = Store.get_sync_state("INBOX")
    end

    test "distinct folders keep independent watermarks" do
      Store.put_sync_state("INBOX", 1, 10)
      Store.put_sync_state("AI/Review", 2, 20)

      assert {:ok, %{uidvalidity: 1, high_water_uid: 10}} = Store.get_sync_state("INBOX")
      assert {:ok, %{uidvalidity: 2, high_water_uid: 20}} = Store.get_sync_state("AI/Review")
    end
  end

  describe "record_outcome/4 + outcomes/1" do
    test "synced and skipped land in their own sets, never in retryable" do
      Store.record_outcome("INBOX", 1, :synced, "msg-1")
      Store.record_outcome("INBOX", 2, :skipped)

      result = Store.outcomes("INBOX")
      assert result.synced == MapSet.new([1])
      assert result.skipped == MapSet.new([2])
      assert result.retryable == []
    end

    test "a failed outcome is retryable, and attempts increments on each repeated failure" do
      Store.record_outcome("INBOX", 3, :failed)
      assert Store.outcomes("INBOX").retryable == [3]

      Store.record_outcome("INBOX", 3, :failed)
      assert Store.outcomes("INBOX").retryable == [3]
    end

    test "retryable drops the uid once attempts reaches 3" do
      Store.record_outcome("INBOX", 3, :failed)
      Store.record_outcome("INBOX", 3, :failed)
      Store.record_outcome("INBOX", 3, :failed)

      assert Store.outcomes("INBOX").retryable == []
    end

    test "record_outcome accepts a string outcome, not just an atom" do
      Store.record_outcome("INBOX", 9, "synced")
      assert Store.outcomes("INBOX").synced == MapSet.new([9])
    end

    test "outcomes only reflects the given folder" do
      Store.record_outcome("INBOX", 1, :synced)
      Store.record_outcome("AI/Review", 1, :skipped)

      assert Store.outcomes("INBOX").synced == MapSet.new([1])
      assert Store.outcomes("INBOX").skipped == MapSet.new([])
      assert Store.outcomes("AI/Review").skipped == MapSet.new([1])
    end
  end

  describe "messages" do
    test "upsert_message + get_message round-trip every field" do
      :ok =
        Store.upsert_message(%{
          msg_id: "2026-07-09-priya-nair-3f2a91c4",
          message_id: "<CAJx1234@mail.example.com>",
          path: "sources/mail/messages/2026-07-09-priya-nair-3f2a91c4.md",
          from: %{name: "Priya Nair", email: "priya@example.com"},
          subject: "Question about leadership coaching",
          date: "2026-07-09T06:58:00Z",
          status: "review",
          has_attachments: false,
          uid: 4711
        })

      assert {:ok, msg} = Store.get_message("2026-07-09-priya-nair-3f2a91c4")
      assert msg.message_id == "<CAJx1234@mail.example.com>"
      assert msg.path == "sources/mail/messages/2026-07-09-priya-nair-3f2a91c4.md"
      assert msg.from_name == "Priya Nair"
      assert msg.from_email == "priya@example.com"
      assert msg.subject == "Question about leadership coaching"
      assert msg.date == "2026-07-09T06:58:00Z"
      assert msg.status == "review"
      assert msg.has_attachments == false
      assert msg.uid == 4711
    end

    test "upsert_message is an upsert keyed by msg_id (dedupe target for later resync)" do
      base = %{
        msg_id: "m1",
        message_id: "<m1@example.com>",
        path: "p1",
        from: %{name: "A", email: "a@example.com"},
        subject: "s1",
        date: "2026-01-01T00:00:00Z",
        status: "review",
        has_attachments: false,
        uid: 1
      }

      Store.upsert_message(base)
      Store.upsert_message(%{base | status: "processed", uid: 2})

      assert {:ok, %{status: "processed", uid: 2}} = Store.get_message("m1")
      assert length(Store.list_messages()) == 1
    end

    test "upsert_message accepts a from map with string keys (frontmatter parsed from YAML)" do
      Store.upsert_message(%{
        msg_id: "m-strkeys",
        message_id: nil,
        path: "p",
        from: %{"name" => "String Keys", "email" => "sk@example.com"},
        subject: "s",
        date: nil,
        status: "review",
        has_attachments: false,
        uid: nil
      })

      assert {:ok, %{from_name: "String Keys", from_email: "sk@example.com"}} =
               Store.get_message("m-strkeys")
    end

    test "upsert_message accepts a DateTime for date and stores it as ISO8601" do
      {:ok, dt, _} = DateTime.from_iso8601("2026-07-09T06:58:00Z")

      Store.upsert_message(%{
        msg_id: "m-dt",
        message_id: nil,
        path: "p",
        from: %{},
        subject: "s",
        date: dt,
        status: "review",
        has_attachments: false,
        uid: nil
      })

      assert {:ok, %{date: "2026-07-09T06:58:00Z"}} = Store.get_message("m-dt")
    end

    test "message_by_message_id finds the row and misses cleanly" do
      Store.upsert_message(%{
        msg_id: "m2",
        message_id: "<dup@example.com>",
        path: "p2",
        from: %{name: "B", email: "b@example.com"},
        subject: "s2",
        date: "2026-07-08T00:00:00Z",
        status: "review",
        has_attachments: true,
        uid: 2
      })

      assert {:ok, %{msg_id: "m2"}} = Store.message_by_message_id("<dup@example.com>")
      assert {:error, :not_found} = Store.message_by_message_id("<nope@example.com>")
    end

    test "list_messages returns newest date first" do
      Store.upsert_message(%{
        msg_id: "older",
        message_id: nil,
        path: "p1",
        from: %{},
        subject: "s",
        date: "2026-01-01T00:00:00Z",
        status: "review",
        has_attachments: false,
        uid: nil
      })

      Store.upsert_message(%{
        msg_id: "newer",
        message_id: nil,
        path: "p2",
        from: %{},
        subject: "s",
        date: "2026-06-01T00:00:00Z",
        status: "review",
        has_attachments: false,
        uid: nil
      })

      assert [%{msg_id: "newer"}, %{msg_id: "older"}] = Store.list_messages()
    end

    test "get_message is :not_found for an unknown msg_id" do
      assert {:error, :not_found} = Store.get_message("nope")
    end

    test "set_message_status updates status and is a silent no-op for an unknown msg_id" do
      Store.upsert_message(%{
        msg_id: "m3",
        message_id: nil,
        path: "p",
        from: %{},
        subject: "s",
        date: nil,
        status: "review",
        has_attachments: false,
        uid: nil
      })

      assert :ok = Store.set_message_status("m3", "processed")
      assert {:ok, %{status: "processed"}} = Store.get_message("m3")

      assert :ok = Store.set_message_status("does-not-exist", "processed")
    end
  end

  describe "clear_folder/1" do
    test "wipes sync_state + outcomes but keeps mail_messages intact" do
      Store.put_sync_state("INBOX", 1, 10)
      Store.record_outcome("INBOX", 1, :synced)

      Store.upsert_message(%{
        msg_id: "keep-me",
        message_id: nil,
        path: "p",
        from: %{},
        subject: "s",
        date: nil,
        status: "review",
        has_attachments: false,
        uid: 1
      })

      assert :ok = Store.clear_folder("INBOX")

      assert {:error, :not_found} = Store.get_sync_state("INBOX")

      assert Store.outcomes("INBOX") == %{
               synced: MapSet.new(),
               skipped: MapSet.new(),
               retryable: []
             }

      assert {:ok, _} = Store.get_message("keep-me")
    end

    test "does not touch a different folder's sync_state" do
      Store.put_sync_state("INBOX", 1, 10)
      Store.put_sync_state("AI/Review", 2, 20)

      Store.clear_folder("INBOX")

      assert {:error, :not_found} = Store.get_sync_state("INBOX")
      assert {:ok, %{uidvalidity: 2, high_water_uid: 20}} = Store.get_sync_state("AI/Review")
    end
  end

  describe "inbox headers" do
    test "put_inbox_header upserts by uid; inbox_headers sorts newest first" do
      Store.put_inbox_header(%{
        uid: 1,
        from_text: "A",
        subject: "one",
        date: "2026-01-01T00:00:00Z"
      })

      Store.put_inbox_header(%{
        uid: 2,
        from_text: "B",
        subject: "two",
        date: "2026-06-01T00:00:00Z"
      })

      Store.put_inbox_header(%{
        uid: 1,
        from_text: "A2",
        subject: "one-edit",
        date: "2026-01-02T00:00:00Z"
      })

      assert [
               %{uid: 2, from_text: "B", subject: "two"},
               %{uid: 1, from_text: "A2", subject: "one-edit"}
             ] = Store.inbox_headers()
    end

    test "prune_inbox_headers keeps only the newest N by date" do
      for i <- 1..5 do
        Store.put_inbox_header(%{
          uid: i,
          from_text: "F#{i}",
          subject: "s#{i}",
          date: "2026-01-0#{i}T00:00:00Z"
        })
      end

      assert :ok = Store.prune_inbox_headers(2)

      assert Store.inbox_headers() |> Enum.map(& &1.uid) == [5, 4]
    end
  end
end
