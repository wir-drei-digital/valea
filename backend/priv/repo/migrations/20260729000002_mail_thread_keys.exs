defmodule Valea.Repo.Migrations.MailThreadKeys do
  @moduledoc """
  Store v5: `mail_messages.thread_key`, the conversation-grouping key behind
  `list_mail_messages(threaded: true)` and the `get_mail_thread` RPC (mail
  full-client plan, M3 task 10).

  One key per OCCURRENCE row (the table's grain), derived at write time by
  `Valea.Mail.Normalizer.thread_key/2` from headers the row already carries —
  `references` head → `in_reply_to` → `message_id` → `msg_id`. It is DERIVED
  state like every other column here: `Valea.Mail.Store.upsert_index_row/1`
  computes it on every write, and `Valea.Mail.Index.rebuild/2` recomputes it
  for every occurrence it re-indexes.

  ## Backfill

  The REAL backfill is `Valea.Mail.Index.rebuild/2`: `Valea.Mail.Engine`'s
  `do_activate/1` runs it on EVERY activation, and every account's engine
  activates when its workspace opens, so an existing store's rows are
  re-upserted — thread key included — the first time the workspace is
  opened after this migration lands. Reimplementing the derivation in SQL
  to do that here would mean maintaining it in two languages, against the
  same rows the rebuild is about to rewrite anyway.

  The `UPDATE` below is therefore not that backfill; it applies only the
  derivation's LAST RESORT ("a message with no usable threading header
  threads alone under its own `msg_id`"), which is trivially correct for
  any row and needs none of the header parsing. Its job is to leave no
  `NULL` keys behind: `NULL`s compare equal for `PARTITION BY`, so a folder
  of not-yet-rebuilt rows would otherwise collapse into one bogus
  conversation for as long as it took the engine to activate. With this,
  the pre-rebuild state is merely COARSE (every message its own thread) and
  the rebuild refines it.

  `Valea.Workspace.*` re-runs `Ecto.Migrator.run/4` on every workspace open,
  but `schema_migrations` keeps an applied version from re-running, so the
  plain `ALTER TABLE ... ADD COLUMN` below (which SQLite would reject as a
  duplicate column on a second run) executes exactly once per database —
  brand-new and long-lived alike.

  The index exists for `Valea.Mail.Store.message_rows_by_thread_key/2`
  (`get_mail_thread`'s cross-folder lookup), which filters on `(account,
  thread_key)` alone — no primary-key prefix to ride on, unlike the
  folder-scoped threaded listing.
  """

  use Ecto.Migration

  def up do
    alter table(:mail_messages) do
      add :thread_key, :string
    end

    # See the moduledoc: the last-resort branch only, so no row is left with
    # a NULL key between this migration and the first `Index.rebuild/2`.
    execute("UPDATE mail_messages SET thread_key = msg_id WHERE thread_key IS NULL")

    create index(:mail_messages, [:account, :thread_key])
  end

  def down do
    drop_if_exists index(:mail_messages, [:account, :thread_key])

    alter table(:mail_messages) do
      remove :thread_key
    end
  end
end
