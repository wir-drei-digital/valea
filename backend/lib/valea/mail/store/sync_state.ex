defmodule Valea.Mail.Store.SyncState do
  @moduledoc """
  Per-folder IMAP sync watermark (`UIDVALIDITY` + high-water `UID`). Pure
  cache: rebuildable from a fresh resync — never the source of truth for
  message content.
  """
  use Ash.Resource,
    domain: Valea.Mail.Store,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "mail_sync_state"
    repo Valea.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true
      accept [:folder, :uidvalidity, :high_water_uid]
      upsert? true
      upsert_fields [:uidvalidity, :high_water_uid]
    end
  end

  attributes do
    attribute :folder, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :uidvalidity, :integer, public?: true
    attribute :high_water_uid, :integer, public?: true
  end
end
