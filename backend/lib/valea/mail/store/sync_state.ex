defmodule Valea.Mail.Store.SyncState do
  @moduledoc """
  Per-account, per-folder IMAP sync watermark and folder-lifecycle bits:
  `UIDVALIDITY`, high-water `UID`, `HIGHESTMODSEQ` (CONDSTORE, when the
  server offers it), whether the folder has completed its initial backfill,
  and whether it is currently held (paused) — plus the local maildir `dir`
  it lands under and light diagnostics (`last_pass_at`, `last_error`). Pure
  cache: rebuildable from a fresh resync — never the source of truth for
  message content.
  """
  use Ash.Resource,
    domain: Valea.Mail.Store,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "mail_sync_state"
    repo Valea.Repo
    # This table is hand-migrated (see the moduledoc + the migration itself,
    # `create_mail_tables.exs`) — never generated. `migrate? false` excludes
    # it from `AshSqlite.MigrationGenerator`'s snapshot diff, which is what
    # both `mix ash.codegen` and `AshPhoenix.Plug.CheckCodegenStatus` (the
    # dev-only endpoint plug that reruns that diff on every request) walk.
    # Without this, dev boots 500 with `Ash.Error.Framework.PendingCodegen`
    # on the very first request, and running codegen would emit a second,
    # redundant "create mail_sync_state" migration racing the hand-written
    # one against an already-migrated table.
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true

      accept [
        :account,
        :folder,
        :dir,
        :uidvalidity,
        :high_water_uid,
        :highestmodseq,
        :backfill_complete,
        :held,
        :last_pass_at,
        :last_error
      ]

      upsert? true

      upsert_fields [
        :dir,
        :uidvalidity,
        :high_water_uid,
        :highestmodseq,
        :backfill_complete,
        :held,
        :last_pass_at,
        :last_error
      ]
    end
  end

  attributes do
    attribute :account, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :folder, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :dir, :string, public?: true
    attribute :uidvalidity, :integer, public?: true
    attribute :high_water_uid, :integer, public?: true
    attribute :highestmodseq, :integer, public?: true
    attribute :backfill_complete, :boolean, default: false, public?: true
    attribute :held, :boolean, default: false, public?: true
    attribute :last_pass_at, :string, public?: true
    attribute :last_error, :string, public?: true
  end
end
