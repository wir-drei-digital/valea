defmodule Valea.Mail.Store.UidOutcome do
  @moduledoc """
  Per-folder, per-UID sync outcome (`synced` / `skipped` / `failed`) with a
  retry-attempt counter. Pure cache: rebuildable by resyncing the folder —
  `Valea.Mail.Store.clear_folder/1` wipes it on a `UIDVALIDITY` mismatch.

  TEMP v3-bridge (mail-as-maildir rebuild, Task 3): the durable
  `mail_pending_ops` ledger (`Valea.Mail.Store.PendingOp`) supersedes
  per-UID outcome tracking conceptually, but `sync_pass.ex`/`sync_pass_test.exs`
  still read/write this table directly (`record_outcome/4`, `outcomes/1`,
  and a raw `Ash.Query` against this resource asserting real persistence) —
  a trivial in-memory or new-table emulation would not satisfy those
  assertions, so this resource + its table are kept alive verbatim,
  recreated by the Task 3 migration alongside the four new tables. Removed
  in Task 7 (`SyncPass` rewrite), when the ops ledger takes over.
  """
  use Ash.Resource,
    domain: Valea.Mail.Store,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "mail_uid_outcomes"
    repo Valea.Repo
    # Hand-migrated table — see the identical comment on
    # `Valea.Mail.Store.SyncState`'s `sqlite` block.
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true
      accept [:folder, :uid, :outcome, :attempts, :msg_id]
      upsert? true
      upsert_fields [:outcome, :attempts, :msg_id]
    end
  end

  attributes do
    attribute :folder, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :uid, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :outcome, :string, public?: true
    attribute :attempts, :integer, default: 0, public?: true
    attribute :msg_id, :string, public?: true
  end
end
