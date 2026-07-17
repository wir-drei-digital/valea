defmodule Valea.Mail.StoreMigrationTest do
  use ExUnit.Case, async: false

  alias Valea.Mail.Store

  # The Task-3 migration replacement scenario (task brief, "Migration"): an
  # existing dev-workspace `app.sqlite` already ran the deleted v1 migration
  # (`20260711000001_create_mail_tables.exs`) — its v1-shape tables and the
  # old `mail_messages (message_id)` index are physically present, and its
  # version is recorded in `schema_migrations`. `Valea.Workspace.*` re-runs
  # `Ecto.Migrator.run/4` on every workspace open, so the replacement
  # migration (`20260717000001`) must boot that database cleanly: drop the
  # v1 leftovers first (`drop_if_exists` — a no-op on fresh DBs, covered by
  # every other test in the suite), then create the v2 schema.
  test "migrator over a v1-shape database drops the leftovers and the new schema works" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-store-mig-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    # Pre-create the v1 shapes by hand, exactly as the deleted
    # `20260711000001_create_mail_tables.exs` left them — including the old
    # `mail_messages (message_id)` index and a `schema_migrations` row for
    # the deleted version (which the migrator must simply ignore: its file
    # is gone, so it is neither re-run nor rolled back).
    for ddl <- [
          """
          CREATE TABLE schema_migrations (
            version INTEGER PRIMARY KEY,
            inserted_at TEXT
          )
          """,
          "INSERT INTO schema_migrations (version, inserted_at) VALUES (20260711000001, '2026-07-11T00:00:01')",
          """
          CREATE TABLE mail_sync_state (
            folder TEXT NOT NULL PRIMARY KEY,
            uidvalidity INTEGER,
            high_water_uid INTEGER
          )
          """,
          """
          CREATE TABLE mail_uid_outcomes (
            folder TEXT NOT NULL,
            uid INTEGER NOT NULL,
            outcome TEXT,
            attempts INTEGER DEFAULT 0,
            msg_id TEXT,
            PRIMARY KEY (folder, uid)
          )
          """,
          """
          CREATE TABLE mail_messages (
            msg_id TEXT NOT NULL PRIMARY KEY,
            message_id TEXT,
            path TEXT,
            from_name TEXT,
            from_email TEXT,
            subject TEXT,
            date TEXT,
            status TEXT,
            has_attachments INTEGER,
            uid INTEGER
          )
          """,
          "CREATE INDEX mail_messages_message_id_index ON mail_messages (message_id)",
          """
          CREATE TABLE mail_inbox_headers (
            uid INTEGER NOT NULL PRIMARY KEY,
            from_text TEXT,
            subject TEXT,
            date TEXT
          )
          """,
          # Stale v1 cache rows — worthless under the v2 layout, must vanish.
          "INSERT INTO mail_sync_state (folder, uidvalidity, high_water_uid) VALUES ('INBOX', 100, 4711)",
          "INSERT INTO mail_messages (msg_id, message_id, status) VALUES ('old-m1', '<old@example.com>', 'review')"
        ] do
      Ecto.Adapters.SQL.query!(Valea.Repo, ddl, [])
    end

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    previous_compiler_options = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous_compiler_options)

    # The v1 cache data is gone with its tables (v2 mail_sync_state has an
    # `account` pk column; v2 mail_messages is occurrence-keyed).
    assert {:error, :not_found} = Store.get_sync_state("mara@example.com", "INBOX")

    assert Ecto.Adapters.SQL.query!(Valea.Repo, "SELECT count(*) FROM mail_messages", []).rows ==
             [[0]]

    # The new schema accepts inserts through the whole v2 API surface.
    assert :ok =
             Store.put_sync_state("mara@example.com", "INBOX", %{
               uidvalidity: 200,
               high_water_uid: 1,
               backfill_complete: true
             })

    assert {:ok, %{uidvalidity: 200, backfill_complete: true}} =
             Store.get_sync_state("mara@example.com", "INBOX")

    assert :ok =
             Store.put_occurrence("mara@example.com", "INBOX", %{
               uid: 1,
               uidvalidity: 200,
               msg_id: "m1",
               flags: MapSet.new(["S"])
             })

    assert [%{msg_id: "m1"}] = Store.occurrences("mara@example.com", "INBOX")

    assert :ok =
             Store.upsert_index_row(%{
               account: "mara@example.com",
               folder: "INBOX",
               uid: 1,
               msg_id: "m1",
               subject: "post-migration",
               date: "2026-07-17T00:00:00Z"
             })

    assert [%{subject: "post-migration"}] = Store.list_messages("mara@example.com", "INBOX")

    # ... including the partial unique index the ledger's claim rests on.
    assert {:ok, op} =
             Store.create_pending_op(%{
               kind: "append",
               account: "mara@example.com",
               origin: "ops:op1:0",
               state: "pending"
             })

    assert {:error, :duplicate_active} =
             Store.create_pending_op(%{
               kind: "append",
               account: "mara@example.com",
               origin: "ops:op1:0",
               state: "pending"
             })

    assert {:ok, %{state: "pending"}} = Store.op_by_id(op.id)
  end
end
