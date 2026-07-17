defmodule Valea.Mail.Store.InboxHeader do
  @moduledoc """
  One row per INBOX header seen (`uid`, `from_text`, `subject`, `date`) —
  feeds `sources/mail/inbox.md` regeneration. Pure cache: pruned to the
  newest N via `Valea.Mail.Store.prune_inbox_headers/1`, rebuildable by
  resyncing INBOX.

  TEMP v3-bridge (mail-as-maildir rebuild, Task 3): `sync_pass.ex` still
  writes real rows here on every INBOX pass and `sync_pass.ex`/`api/mail.ex`
  render `sources/mail/inbox.md`/`mail_inbox` straight off this table, with
  `cockpit_test.exs`/`mail_rpc_test.exs` asserting real round-trips — kept
  alive verbatim, recreated by the Task 3 migration alongside the four new
  tables. Removed once INBOX awareness is rebuilt on the new occurrence
  tables (Task 6/7).
  """
  use Ash.Resource,
    domain: Valea.Mail.Store,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "mail_inbox_headers"
    repo Valea.Repo
    # Hand-migrated table — see the identical comment on
    # `Valea.Mail.Store.SyncState`'s `sqlite` block.
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true
      accept [:uid, :from_text, :subject, :date]
      upsert? true
      upsert_fields [:from_text, :subject, :date]
    end
  end

  attributes do
    attribute :uid, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :from_text, :string, public?: true
    attribute :subject, :string, public?: true
    attribute :date, :string, public?: true
  end
end
