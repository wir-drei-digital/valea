defmodule Valea.Repo.Migrations.CreateMailTables do
  @moduledoc """
  First real workspace-DB migration. All four `Valea.Mail.Store` tables are
  pure cache — rebuildable from `sources/mail/` (+ IMAP resync) — so this
  migration is hand-written rather than generated: no ash_sqlite
  codegen/snapshots machinery for these resources.
  """

  use Ecto.Migration

  def up do
    create table(:mail_sync_state, primary_key: false) do
      add :folder, :string, primary_key: true, null: false
      add :uidvalidity, :integer
      add :high_water_uid, :integer
    end

    create table(:mail_uid_outcomes, primary_key: false) do
      add :folder, :string, primary_key: true, null: false
      add :uid, :integer, primary_key: true, null: false
      add :outcome, :string
      add :attempts, :integer, default: 0
      add :msg_id, :string
    end

    create table(:mail_messages, primary_key: false) do
      add :msg_id, :string, primary_key: true, null: false
      add :message_id, :string
      add :path, :string
      add :from_name, :string
      add :from_email, :string
      add :subject, :string
      add :date, :string
      add :status, :string
      add :has_attachments, :integer
      add :uid, :integer
    end

    create index(:mail_messages, [:message_id])

    create table(:mail_inbox_headers, primary_key: false) do
      add :uid, :integer, primary_key: true, null: false
      add :from_text, :string
      add :subject, :string
      add :date, :string
    end
  end

  def down do
    drop table(:mail_inbox_headers)
    drop index(:mail_messages, [:message_id])
    drop table(:mail_messages)
    drop table(:mail_uid_outcomes)
    drop table(:mail_sync_state)
  end
end
