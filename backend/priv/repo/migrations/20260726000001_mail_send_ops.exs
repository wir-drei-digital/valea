defmodule Valea.Repo.Migrations.MailSendOps do
  @moduledoc """
  Store v3: the `send` op kind (mail SMTP-send design spec G, §Send
  pipeline). Hand-migrated like every other mail table — see the
  `migrate? false` comment on `Valea.Mail.Store.PendingOp`.

  Two changes to `mail_pending_ops`:

    1. Four columns a send op needs and a move/append never had:
       `content_hash` (the RAW reviewed bytes' hash — the display
       projection's gate for "is the file still the revision that was
       sent?"), `wire_sha256`/`record_sha256` (the two spooled byte
       variants, re-verified before the one transmit and before the Sent
       copy), and `envelope_rcpt` (the JSON array of bare addr-specs the
       envelope carried).
    2. The atomic-claim partial unique index is WIDENED across both
       outbound kinds: `mail_pending_ops_active_append` (append only)
       becomes `mail_pending_ops_active_outbound` (append + send), so one
       draft can never be pushed and sent concurrently, nor sent twice
       from two tabs. The `transmitted`/`send_review` states are
       deliberately NOT in the terminal exclusion list — an op that
       transmitted but hasn't filed its Sent copy, or one parked for human
       resolution, still holds its draft's claim.

  `Valea.Workspace.*` re-runs `Ecto.Migrator.run/4` on every workspace
  open, so this must be safe on a database that already ran
  `20260717000001` (drop the old index) as well as a brand-new one.
  """

  use Ecto.Migration

  def up do
    alter table(:mail_pending_ops) do
      add :content_hash, :string
      add :wire_sha256, :string
      add :record_sha256, :string
      add :envelope_rcpt, :string
    end

    drop_if_exists index(:mail_pending_ops, [:account, :origin],
                     name: :mail_pending_ops_active_append
                   )

    create index(:mail_pending_ops, [:account, :origin],
             unique: true,
             where: "kind IN ('append','send') AND state NOT IN ('rejected','complete')",
             name: :mail_pending_ops_active_outbound
           )
  end

  def down do
    drop_if_exists index(:mail_pending_ops, [:account, :origin],
                     name: :mail_pending_ops_active_outbound
                   )

    create index(:mail_pending_ops, [:account, :origin],
             unique: true,
             where: "kind = 'append' AND state NOT IN ('rejected','complete')",
             name: :mail_pending_ops_active_append
           )

    alter table(:mail_pending_ops) do
      remove :content_hash
      remove :wire_sha256
      remove :record_sha256
      remove :envelope_rcpt
    end
  end
end
