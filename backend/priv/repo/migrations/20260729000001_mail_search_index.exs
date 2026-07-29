defmodule Valea.Repo.Migrations.MailSearchIndex do
  @moduledoc """
  Store v4: `mail_search`, the FTS5 full-text index behind the `search_mail`
  RPC (mail full-client plan, M3 task 8).

  One row per (account, msg_id) — per MESSAGE, not per occurrence: the
  shared view under `sources/mail/<account>/views/messages/<msg_id>.md` is
  what gets indexed, so a message carrying three Gmail labels is one search
  hit, not three. `account`/`msg_id` are `UNINDEXED` (they are the row's
  identity, never search terms); `from_text`/`subject`/`body` carry the
  tokenized text.

  Raw `execute/1` rather than Ecto's `create table` DSL: `USING fts5(...)`
  with its `tokenize`/`prefix` options has no DSL spelling, and the exact
  statement is load-bearing (changing the tokenizer or the prefix set
  silently changes what matches).

  ## Why this migration is pure DROP-then-CREATE, with no ALTER path

  An FTS5 virtual table cannot be `ALTER`ed like an ordinary table (no
  added/dropped/retyped columns, no tokenizer change) — so there is no
  incremental evolution to write. Any future change to the schema below is
  a new migration that drops and recreates the table; nothing is lost,
  because this index is DERIVED state. `Valea.Mail.Index.rebuild/2` truncates
  and re-feeds it from the view files on disk (the source of truth), and is
  the repair path for an empty, stale, or freshly recreated index.

  `Valea.Workspace.*` re-runs `Ecto.Migrator.run/4` on every workspace open,
  so `up/0` leads with a `DROP TABLE IF EXISTS` — safe on a brand-new
  database and on one where a partially-applied earlier attempt left the
  table behind, same posture as `20260717000001`'s `drop_if_exists` prelude.
  """

  use Ecto.Migration

  def up do
    execute("DROP TABLE IF EXISTS mail_search")

    execute("""
    CREATE VIRTUAL TABLE mail_search USING fts5(
      account UNINDEXED,
      msg_id UNINDEXED,
      from_text,
      subject,
      body,
      tokenize='unicode61',
      prefix='2 3'
    )
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS mail_search")
  end
end
