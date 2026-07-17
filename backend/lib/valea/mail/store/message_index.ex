defmodule Valea.Mail.Store.MessageIndex do
  @moduledoc """
  Index over landed maildir occurrences — ONE ROW PER `(account, folder,
  uid)` OCCURRENCE, not one row per message: the same `msg_id` can appear
  in more than one folder (e.g. a draft pushed to `Drafts` and later found
  in `INBOX`/`Sent` after append), and each occurrence gets its own row so
  a folder listing never has to guess which occurrence it's looking at.
  `msg_id` is deliberately NOT unique here (see `occurrences_by_msg_id/2`,
  `message_rows_by_msg_id/2`). Pure cache: rebuildable in full from a
  maildir scan; `path` is the source of truth for content, this row is only
  ever derived from it.
  """
  use Ash.Resource,
    domain: Valea.Mail.Store,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "mail_messages"
    repo Valea.Repo
    # Hand-migrated table — see the identical comment on
    # `Valea.Mail.Store.SyncState`'s `sqlite` block.
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true

      accept [
        :account,
        :folder,
        :uid,
        :msg_id,
        :message_id,
        :from_name,
        :from_email,
        :subject,
        :date,
        :flags,
        :has_attachments,
        :path,
        :in_reply_to,
        :references
      ]

      upsert? true

      upsert_fields [
        :msg_id,
        :message_id,
        :from_name,
        :from_email,
        :subject,
        :date,
        :flags,
        :has_attachments,
        :path,
        :in_reply_to,
        :references
      ]
    end

    update :set_flags do
      accept [:flags, :path]
    end
  end

  attributes do
    attribute :account, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :folder, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :uid, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :msg_id, :string, public?: true
    attribute :message_id, :string, public?: true
    attribute :from_name, :string, public?: true
    attribute :from_email, :string, public?: true
    attribute :subject, :string, public?: true
    attribute :date, :string, public?: true
    attribute :flags, :string, public?: true
    attribute :has_attachments, :boolean, default: false, public?: true
    attribute :path, :string, public?: true
    attribute :in_reply_to, :string, public?: true
    attribute :references, :string, public?: true
  end
end
