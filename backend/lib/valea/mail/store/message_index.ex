defmodule Valea.Mail.Store.MessageIndex do
  @moduledoc """
  Index over `sources/mail/messages/*.md` — the metadata a list view needs
  without re-parsing every file. Pure cache: rebuildable in full by
  `Valea.Mail.Index.rebuild/1`; `path` is the source of truth for content,
  this row is only ever derived from it.
  """
  use Ash.Resource,
    domain: Valea.Mail.Store,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "mail_messages"
    repo Valea.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true

      accept [
        :msg_id,
        :message_id,
        :path,
        :from_name,
        :from_email,
        :subject,
        :date,
        :status,
        :has_attachments,
        :uid
      ]

      upsert? true

      upsert_fields [
        :message_id,
        :path,
        :from_name,
        :from_email,
        :subject,
        :date,
        :status,
        :has_attachments,
        :uid
      ]
    end

    update :set_status do
      accept [:status]
    end
  end

  attributes do
    attribute :msg_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :message_id, :string, public?: true
    attribute :path, :string, public?: true
    attribute :from_name, :string, public?: true
    attribute :from_email, :string, public?: true
    attribute :subject, :string, public?: true
    attribute :date, :string, public?: true
    attribute :status, :string, public?: true
    attribute :has_attachments, :boolean, default: false, public?: true
    attribute :uid, :integer, public?: true
  end
end
