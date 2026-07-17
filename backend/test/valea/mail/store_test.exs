defmodule Valea.Mail.StoreTest do
  use ExUnit.Case, async: false

  alias Valea.Mail.Store

  defp base_row(overrides) do
    Map.merge(
      %{
        account: "mara@example.com",
        folder: "INBOX",
        uid: 1,
        msg_id: "m1",
        message_id: "<m1@example.com>",
        from_name: "A",
        from_email: "a@example.com",
        subject: "s",
        date: "2026-01-01T00:00:00Z",
        flags: "S",
        has_attachments: false,
        path: "sources/mail/messages/m1.md",
        in_reply_to: nil,
        references: nil
      },
      overrides
    )
  end

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

  describe "sync_state (v2)" do
    test "get_sync_state/2 is :not_found before anything is written" do
      assert {:error, :not_found} = Store.get_sync_state("mara@example.com", "INBOX")
    end

    test "put_sync_state/3 upserts every field, including backfill_complete/held" do
      assert :ok =
               Store.put_sync_state("mara@example.com", "INBOX", %{
                 dir: "INBOX",
                 uidvalidity: 100,
                 high_water_uid: 4711,
                 highestmodseq: 55,
                 backfill_complete: true,
                 held: false,
                 last_pass_at: "2026-07-17T00:00:00Z",
                 last_error: nil
               })

      assert {:ok, state} = Store.get_sync_state("mara@example.com", "INBOX")
      assert state.dir == "INBOX"
      assert state.uidvalidity == 100
      assert state.high_water_uid == 4711
      assert state.highestmodseq == 55
      assert state.backfill_complete == true
      assert state.held == false
      assert state.last_pass_at == "2026-07-17T00:00:00Z"
    end

    test "put_sync_state/3 is a partial upsert: only the given keys change" do
      Store.put_sync_state("mara@example.com", "INBOX", %{uidvalidity: 100, high_water_uid: 10})
      Store.put_sync_state("mara@example.com", "INBOX", %{high_water_uid: 20})

      assert {:ok, %{uidvalidity: 100, high_water_uid: 20}} =
               Store.get_sync_state("mara@example.com", "INBOX")
    end

    test "distinct (account, folder) pairs keep independent watermarks" do
      Store.put_sync_state("mara@example.com", "INBOX", %{uidvalidity: 1, high_water_uid: 10})
      Store.put_sync_state("mara@example.com", "AI/Review", %{uidvalidity: 2, high_water_uid: 20})
      Store.put_sync_state("priya@example.com", "INBOX", %{uidvalidity: 3, high_water_uid: 30})

      assert {:ok, %{uidvalidity: 1, high_water_uid: 10}} =
               Store.get_sync_state("mara@example.com", "INBOX")

      assert {:ok, %{uidvalidity: 2, high_water_uid: 20}} =
               Store.get_sync_state("mara@example.com", "AI/Review")

      assert {:ok, %{uidvalidity: 3, high_water_uid: 30}} =
               Store.get_sync_state("priya@example.com", "INBOX")
    end

    test "folders/1 returns every sync_state row for the account, not other accounts'" do
      Store.put_sync_state("mara@example.com", "INBOX", %{uidvalidity: 1})
      Store.put_sync_state("mara@example.com", "AI/Review", %{uidvalidity: 2})
      Store.put_sync_state("priya@example.com", "INBOX", %{uidvalidity: 9})

      rows = Store.folders("mara@example.com")
      assert length(rows) == 2
      assert Enum.map(rows, & &1.folder) |> Enum.sort() == ["AI/Review", "INBOX"]
    end

    test "mark_held/3 flips held without disturbing other columns" do
      Store.put_sync_state("mara@example.com", "INBOX", %{uidvalidity: 1, high_water_uid: 10})
      assert :ok = Store.mark_held("mara@example.com", "INBOX", true)

      assert {:ok, %{held: true, uidvalidity: 1, high_water_uid: 10}} =
               Store.get_sync_state("mara@example.com", "INBOX")

      assert :ok = Store.mark_held("mara@example.com", "INBOX", false)
      assert {:ok, %{held: false}} = Store.get_sync_state("mara@example.com", "INBOX")
    end
  end

  describe "occurrences (mail_uid_map)" do
    test "put_occurrence/3 + occurrences/2 round-trip, flags as a MapSet" do
      Store.put_occurrence("mara@example.com", "INBOX", %{
        uid: 1,
        uidvalidity: 100,
        msg_id: "m1",
        flags: MapSet.new(["S", "F"])
      })

      assert [row] = Store.occurrences("mara@example.com", "INBOX")
      assert row.uid == 1
      assert row.uidvalidity == 100
      assert row.msg_id == "m1"
      assert row.flags == MapSet.new(["F", "S"])
    end

    test "put_occurrence/3 upserts by (account, folder, uid)" do
      Store.put_occurrence("mara@example.com", "INBOX", %{
        uid: 1,
        uidvalidity: 100,
        msg_id: "m1",
        flags: MapSet.new(["S"])
      })

      Store.put_occurrence("mara@example.com", "INBOX", %{
        uid: 1,
        uidvalidity: 100,
        msg_id: "m1",
        flags: MapSet.new(["S", "F"])
      })

      assert [row] = Store.occurrences("mara@example.com", "INBOX")
      assert row.flags == MapSet.new(["F", "S"])
    end

    test "delete_occurrence/3 removes exactly that row" do
      Store.put_occurrence("mara@example.com", "INBOX", %{
        uid: 1,
        uidvalidity: 100,
        msg_id: "m1",
        flags: MapSet.new()
      })

      Store.put_occurrence("mara@example.com", "INBOX", %{
        uid: 2,
        uidvalidity: 100,
        msg_id: "m2",
        flags: MapSet.new()
      })

      assert :ok = Store.delete_occurrence("mara@example.com", "INBOX", 1)

      assert Store.occurrences("mara@example.com", "INBOX") |> Enum.map(& &1.uid) == [2]
    end

    test "delete_occurrence/3 on a missing row is a no-op" do
      assert :ok = Store.delete_occurrence("mara@example.com", "INBOX", 999)
    end

    test "occurrences_by_msg_id/2 finds the same msg_id across folders" do
      Store.put_occurrence("mara@example.com", "INBOX", %{
        uid: 1,
        uidvalidity: 100,
        msg_id: "shared",
        flags: MapSet.new()
      })

      Store.put_occurrence("mara@example.com", "AI/Review", %{
        uid: 5,
        uidvalidity: 200,
        msg_id: "shared",
        flags: MapSet.new()
      })

      Store.put_occurrence("mara@example.com", "INBOX", %{
        uid: 2,
        uidvalidity: 100,
        msg_id: "other",
        flags: MapSet.new()
      })

      rows = Store.occurrences_by_msg_id("mara@example.com", "shared")
      assert length(rows) == 2
      assert Enum.map(rows, & &1.folder) |> Enum.sort() == ["AI/Review", "INBOX"]
    end
  end

  describe "index rows (mail_messages occurrences)" do
    test "upsert_index_row/1 + list_messages/2 round-trips every field" do
      assert :ok = Store.upsert_index_row(base_row(%{}))

      assert [row] = Store.list_messages("mara@example.com", "INBOX")
      assert row.uid == 1
      assert row.msg_id == "m1"
      assert row.message_id == "<m1@example.com>"
      assert row.from_name == "A"
      assert row.from_email == "a@example.com"
      assert row.subject == "s"
      assert row.date == "2026-01-01T00:00:00Z"
      assert row.flags == "S"
      assert row.has_attachments == false
      assert row.path == "sources/mail/messages/m1.md"
    end

    test "the same msg_id in two different folders lands two occurrence rows, both listed" do
      Store.upsert_index_row(base_row(%{folder: "INBOX", uid: 1}))
      Store.upsert_index_row(base_row(%{folder: "Drafts", uid: 7}))

      rows = Store.message_rows_by_msg_id("mara@example.com", "m1")
      assert length(rows) == 2
      assert Enum.map(rows, & &1.folder) |> Enum.sort() == ["Drafts", "INBOX"]
    end

    test "list_messages/4 paginates: limit + before cursor, newest date first" do
      Store.upsert_index_row(base_row(%{uid: 1, msg_id: "oldest", date: "2026-01-01T00:00:00Z"}))
      Store.upsert_index_row(base_row(%{uid: 2, msg_id: "middle", date: "2026-01-02T00:00:00Z"}))
      Store.upsert_index_row(base_row(%{uid: 3, msg_id: "newest", date: "2026-01-03T00:00:00Z"}))

      assert Store.list_messages("mara@example.com", "INBOX", 2)
             |> Enum.map(& &1.msg_id) == ["newest", "middle"]

      assert Store.list_messages("mara@example.com", "INBOX", 2, "2026-01-02T00:00:00Z")
             |> Enum.map(& &1.msg_id) == ["oldest"]
    end

    test "delete_index_row/3 removes exactly that occurrence" do
      Store.upsert_index_row(base_row(%{uid: 1}))
      Store.upsert_index_row(base_row(%{uid: 2, msg_id: "m2"}))

      assert :ok = Store.delete_index_row("mara@example.com", "INBOX", 1)

      assert Store.list_messages("mara@example.com", "INBOX") |> Enum.map(& &1.uid) == [2]
    end

    test "delete_index_rows/2 wipes every occurrence for the folder" do
      Store.upsert_index_row(base_row(%{uid: 1}))
      Store.upsert_index_row(base_row(%{uid: 2, msg_id: "m2"}))
      Store.upsert_index_row(base_row(%{folder: "Drafts", uid: 3, msg_id: "m3"}))

      assert :ok = Store.delete_index_rows("mara@example.com", "INBOX")

      assert Store.list_messages("mara@example.com", "INBOX") == []
      assert Store.list_messages("mara@example.com", "Drafts") |> length() == 1
    end
  end

  describe "clear_folder/2" do
    test "wipes sync_state + uid_map + index rows for that (account, folder) only" do
      Store.put_sync_state("mara@example.com", "INBOX", %{uidvalidity: 1, high_water_uid: 10})

      Store.put_occurrence("mara@example.com", "INBOX", %{
        uid: 1,
        uidvalidity: 1,
        msg_id: "m1",
        flags: MapSet.new()
      })

      Store.upsert_index_row(base_row(%{}))

      Store.put_sync_state("mara@example.com", "AI/Review", %{uidvalidity: 2, high_water_uid: 20})
      Store.put_sync_state("priya@example.com", "INBOX", %{uidvalidity: 3, high_water_uid: 30})

      assert :ok = Store.clear_folder("mara@example.com", "INBOX")

      assert {:error, :not_found} = Store.get_sync_state("mara@example.com", "INBOX")
      assert Store.occurrences("mara@example.com", "INBOX") == []
      assert Store.list_messages("mara@example.com", "INBOX") == []

      assert {:ok, %{uidvalidity: 2, high_water_uid: 20}} =
               Store.get_sync_state("mara@example.com", "AI/Review")

      assert {:ok, %{uidvalidity: 3, high_water_uid: 30}} =
               Store.get_sync_state("priya@example.com", "INBOX")
    end
  end

  describe "pending ops ledger" do
    defp op_attrs(overrides) do
      Map.merge(
        %{
          kind: "append",
          account: "mara@example.com",
          origin: "ops:op1:0",
          state: "pending",
          msg_id: "m1"
        },
        overrides
      )
    end

    test "create_pending_op/1 generates an id and stamps inserted_at/updated_at" do
      assert {:ok, op} = Store.create_pending_op(op_attrs(%{}))
      assert is_binary(op.id)
      assert op.kind == "append"
      assert op.state == "pending"
      assert is_binary(op.inserted_at)
      assert is_binary(op.updated_at)
    end

    test "a second active append for the same (account, origin) is rejected" do
      assert {:ok, _op1} = Store.create_pending_op(op_attrs(%{state: "pending"}))

      assert {:error, :duplicate_active} =
               Store.create_pending_op(op_attrs(%{state: "claimed"}))
    end

    test "after the active op transitions to complete, a new claim on the same origin succeeds" do
      assert {:ok, op1} = Store.create_pending_op(op_attrs(%{}))
      assert {:error, :duplicate_active} = Store.create_pending_op(op_attrs(%{}))

      assert :ok = Store.transition_op(op1.id, "complete")

      assert {:ok, op2} = Store.create_pending_op(op_attrs(%{}))
      assert op2.id != op1.id
    end

    test "after the active op is rejected, a new claim on the same origin also succeeds" do
      assert {:ok, op1} = Store.create_pending_op(op_attrs(%{}))
      assert :ok = Store.transition_op(op1.id, "rejected", %{error: "bad payload"})

      assert {:ok, _op2} = Store.create_pending_op(op_attrs(%{}))
    end

    test "the duplicate-active constraint only applies to kind \"append\"" do
      assert {:ok, _} =
               Store.create_pending_op(op_attrs(%{kind: "move", origin: "rpc", state: "pending"}))

      assert {:ok, _} =
               Store.create_pending_op(op_attrs(%{kind: "move", origin: "rpc", state: "claimed"}))
    end

    test "transition_op/3 merges extra fields and updates state" do
      assert {:ok, op1} = Store.create_pending_op(op_attrs(%{}))

      assert :ok =
               Store.transition_op(op1.id, "executing", %{
                 uid: 42,
                 dest_watermark: 100,
                 dest_uidvalidity: 7
               })

      assert {:ok, op} = Store.op_by_id(op1.id)
      assert op.state == "executing"
      assert op.uid == 42
      assert op.dest_watermark == 100
      assert op.dest_uidvalidity == 7
    end

    test "transition_op/3 on an unknown id is a silent no-op" do
      assert :ok = Store.transition_op("does-not-exist", "complete")
    end

    test "pending_ops/1 lists only in-flight states, scoped to the account" do
      {:ok, op1} = Store.create_pending_op(op_attrs(%{origin: "ops:op1:0"}))
      {:ok, op2} = Store.create_pending_op(op_attrs(%{origin: "ops:op2:0", state: "claimed"}))
      {:ok, op3} = Store.create_pending_op(op_attrs(%{origin: "ops:op3:0"}))
      Store.transition_op(op3.id, "complete")

      {:ok, _other_account} =
        Store.create_pending_op(op_attrs(%{account: "priya@example.com", origin: "ops:op9:0"}))

      ids = Store.pending_ops("mara@example.com") |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([op1.id, op2.id])
    end

    test "op_by_id/1 misses cleanly for an unknown id" do
      assert {:error, :not_found} = Store.op_by_id("does-not-exist")
    end
  end

  # -- TEMP v3-bridge coverage ---------------------------------------------
  # Direct unit coverage (beyond the indirect coverage `index_test.exs`,
  # `sync_pass_test.exs`, `cockpit_test.exs`, and `mail_rpc_test.exs` already
  # give the bridge) for the parts of it those suites don't happen to
  # exercise — dedupe-on-uid-change in particular. Removed alongside the
  # bridge functions themselves (Task 6/7/9).

  describe "legacy bridge: sync_state" do
    test "get_sync_state/1 + put_sync_state/3 (old 3-arg shape) round-trip" do
      assert {:error, :not_found} = Store.get_sync_state("INBOX")

      assert :ok = Store.put_sync_state("INBOX", 100, 4711)
      assert {:ok, %{uidvalidity: 100, high_water_uid: 4711}} = Store.get_sync_state("INBOX")

      assert :ok = Store.put_sync_state("INBOX", 100, 4800)
      assert {:ok, %{uidvalidity: 100, high_water_uid: 4800}} = Store.get_sync_state("INBOX")
    end
  end

  describe "legacy bridge: messages" do
    test "upsert_message/1 + get_message/1 round-trip, status riding along in flags" do
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
      assert msg.from_name == "Priya Nair"
      assert msg.from_email == "priya@example.com"
      assert msg.status == "review"
      assert msg.has_attachments == false
      assert msg.uid == 4711
    end

    test "upsert_message/1 dedupes by msg_id even when uid changes (occurrence pk otherwise splits it)" do
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

    test "upsert_message/1 accepts a from map with string keys" do
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

    test "message_by_message_id/1 finds the row and misses cleanly" do
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

    test "list_messages/0 returns newest date first" do
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

    test "set_message_status/2 updates status (via flags) and is a silent no-op for an unknown msg_id" do
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

  describe "legacy bridge: clear_folder/1" do
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

  describe "legacy bridge: record_outcome/4 + outcomes/1" do
    test "synced and skipped land in their own sets, never in retryable" do
      Store.record_outcome("INBOX", 1, :synced, "msg-1")
      Store.record_outcome("INBOX", 2, :skipped_oversize, "msg-2")
      Store.record_outcome("INBOX", 4, :skipped)

      result = Store.outcomes("INBOX")
      assert result.synced == MapSet.new([1])
      assert result.skipped == MapSet.new([2, 4])
      assert result.retryable == []
    end

    test "retryable drops the uid once attempts reaches 3" do
      Store.record_outcome("INBOX", 3, :failed)
      Store.record_outcome("INBOX", 3, :failed)
      assert Store.outcomes("INBOX").retryable == [3]

      Store.record_outcome("INBOX", 3, :failed)
      assert Store.outcomes("INBOX").retryable == []
    end
  end

  describe "legacy bridge: inbox headers" do
    test "put_inbox_header/1 upserts by uid; inbox_headers/0 sorts newest first; prune keeps newest N" do
      for i <- 1..3 do
        Store.put_inbox_header(%{
          uid: i,
          from_text: "F#{i}",
          subject: "s#{i}",
          date: "2026-01-0#{i}T00:00:00Z"
        })
      end

      assert Store.inbox_headers() |> Enum.map(& &1.uid) == [3, 2, 1]

      assert :ok = Store.prune_inbox_headers(2)
      assert Store.inbox_headers() |> Enum.map(& &1.uid) == [3, 2]
    end
  end
end
