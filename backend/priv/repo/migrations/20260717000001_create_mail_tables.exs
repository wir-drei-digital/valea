defmodule Valea.Repo.Migrations.CreateMailTables do
  @moduledoc """
  Store v2: occurrence-based `mail_sync_state`/`mail_uid_map`/`mail_messages`
  tables plus the durable `mail_pending_ops` ledger. Every one of these
  tables is hand-migrated (no ash_sqlite codegen/snapshots) — see the
  `migrate? false` comment on each `Valea.Mail.Store.*` resource.

  `up/0` FIRST drops the v1 shapes (`20260711000001_create_mail_tables.exs`,
  deleted alongside this migration): an existing dev-workspace `app.sqlite`
  already ran that migration and has these tables on disk, and
  `Valea.Workspace.*` re-runs `Ecto.Migrator.run/4` on every workspace open —
  so this migration must be safe against both a brand-new database
  (`drop_if_exists` no-ops) and an already-migrated v1 one (whose cache is
  worthless under the new occurrence-based layout and must not block boot).

  `mail_uid_outcomes` and `mail_inbox_headers` are dropped and immediately
  recreated in their v1 shape: `Valea.Mail.Store.UidOutcome` (bridge retired
  Task 7) and `Valea.Mail.Store.InboxHeader` (bridge retired Task 10, the
  resource itself deleted) both used them as a pre-occurrence bridge table
  in their day. Both tables' schema is left in place here regardless —
  hand-written migrations aren't retroactively edited; an orphaned table is
  harmless — see `Valea.Mail.Store`'s moduledoc.
  """

  use Ecto.Migration

  def up do
    drop_if_exists index(:mail_messages, [:message_id])
    drop_if_exists table(:mail_sync_state)
    drop_if_exists table(:mail_uid_outcomes)
    drop_if_exists table(:mail_messages)
    drop_if_exists table(:mail_inbox_headers)

    create table(:mail_sync_state, primary_key: false) do
      add :account, :string, primary_key: true, null: false
      add :folder, :string, primary_key: true, null: false
      add :dir, :string
      add :uidvalidity, :integer
      add :high_water_uid, :integer
      add :highestmodseq, :integer
      add :backfill_complete, :boolean, default: false
      add :held, :boolean, default: false
      add :last_pass_at, :string
      add :last_error, :string
    end

    create table(:mail_uid_map, primary_key: false) do
      add :account, :string, primary_key: true, null: false
      add :folder, :string, primary_key: true, null: false
      add :uid, :integer, primary_key: true, null: false
      add :uidvalidity, :integer
      add :msg_id, :string
      add :last_synced_flags, :string
    end

    create table(:mail_messages, primary_key: false) do
      add :account, :string, primary_key: true, null: false
      add :folder, :string, primary_key: true, null: false
      add :uid, :integer, primary_key: true, null: false
      add :msg_id, :string
      add :message_id, :string
      add :from_name, :string
      add :from_email, :string
      add :subject, :string
      add :date, :string
      add :flags, :string
      add :has_attachments, :boolean, default: false
      add :path, :string
      add :in_reply_to, :string
      add :references, :string
    end

    # Historical bridge tables (v1 shape, unchanged) — see the moduledoc
    # above: both bridges are since retired, the tables left in place.
    create table(:mail_uid_outcomes, primary_key: false) do
      add :folder, :string, primary_key: true, null: false
      add :uid, :integer, primary_key: true, null: false
      add :outcome, :string
      add :attempts, :integer, default: 0
      add :msg_id, :string
    end

    create table(:mail_inbox_headers, primary_key: false) do
      add :uid, :integer, primary_key: true, null: false
      add :from_text, :string
      add :subject, :string
      add :date, :string
    end

    create table(:mail_pending_ops, primary_key: false) do
      add :id, :string, primary_key: true, null: false
      add :kind, :string, null: false
      add :account, :string, null: false
      add :source_folder, :string
      add :target_folder, :string
      add :uid, :integer
      add :source_uidvalidity, :integer
      add :dest_watermark, :integer
      add :dest_uidvalidity, :integer
      add :message_id, :string
      add :msg_id, :string
      add :origin, :string, null: false
      add :spool_path, :string
      add :payload_sha256, :string
      add :state, :string, null: false
      add :error, :string
      add :inserted_at, :string
      add :updated_at, :string
    end

    create index(:mail_messages, [:account, :msg_id])
    create index(:mail_uid_map, [:account, :msg_id])

    # The atomic push claim: at most one non-terminal ("rejected"/"complete"
    # excluded) append per (account, origin) — a SQLite partial unique index,
    # not an Ash identity (see `Valea.Mail.Store.PendingOp`'s moduledoc).
    create index(:mail_pending_ops, [:account, :origin],
             unique: true,
             where: "kind = 'append' AND state NOT IN ('rejected','complete')",
             name: :mail_pending_ops_active_append
           )
  end

  def down do
    drop index(:mail_pending_ops, [:account, :origin], name: :mail_pending_ops_active_append)
    drop index(:mail_uid_map, [:account, :msg_id])
    drop index(:mail_messages, [:account, :msg_id])
    drop table(:mail_pending_ops)
    drop table(:mail_inbox_headers)
    drop table(:mail_uid_outcomes)
    drop table(:mail_messages)
    drop table(:mail_uid_map)
    drop table(:mail_sync_state)
  end
end
