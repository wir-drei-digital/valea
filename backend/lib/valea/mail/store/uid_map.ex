defmodule Valea.Mail.Store.UidMap do
  @moduledoc """
  Per-account, per-folder IMAP `UID` -> local identity map: which `msg_id`
  (the maildir-stable id) a given `UID` last resolved to, under which
  `UIDVALIDITY`, and the maildir flag letters last synced from the server
  (`last_synced_flags`, e.g. `"FS"` — sorted, matching
  `Valea.Mail.Maildir.encode_filename/3`'s convention). Pure cache:
  rebuildable from a fresh IMAP resync — never the source of truth for
  message content or flags (the maildir filename is).
  """
  use Ash.Resource,
    domain: Valea.Mail.Store,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "mail_uid_map"
    repo Valea.Repo
    # Hand-migrated table — see the identical comment on
    # `Valea.Mail.Store.SyncState`'s `sqlite` block.
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true
      accept [:account, :folder, :uid, :uidvalidity, :msg_id, :last_synced_flags]
      upsert? true
      upsert_fields [:uidvalidity, :msg_id, :last_synced_flags]
    end
  end

  attributes do
    attribute :account, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :folder, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :uid, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :uidvalidity, :integer, public?: true
    attribute :msg_id, :string, public?: true
    attribute :last_synced_flags, :string, public?: true
  end
end
