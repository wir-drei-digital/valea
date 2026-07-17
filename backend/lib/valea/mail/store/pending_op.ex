defmodule Valea.Mail.Store.PendingOp do
  @moduledoc """
  The durable ops ledger — one row per push operation (`"move"` from a
  reviewed message to its destination folder, or `"append"` of a pushed
  draft) as it is claimed, executed, and resolved. Unlike every other
  `Valea.Mail.Store` table, this one is NOT pure cache: it is the record of
  in-flight/at-most-once side effects against the remote mailbox, so a
  crash mid-push must find its own row again on restart rather than risk a
  duplicate append or a re-executed move.

  `id` is an opaque, caller-generated `Ash.UUID` (assigned by
  `Valea.Mail.Store.create_pending_op/1`, not database-generated) — the
  handle `transition_op/3`/`op_by_id/1` key off. `state` walks
  `"claimed" -> "pending" -> "executing" -> "complete"`, with `"rejected"`
  and `"needs_review"` as terminal/parked side branches.

  The one-non-terminal-push-per-draft invariant — a given `(account,
  origin)` append can have at most one row that is neither `"rejected"` nor
  `"complete"` — is enforced by a hand-written SQLite **partial** unique
  index (`mail_pending_ops_active_append`, see the migration), not an Ash
  `identity`: `Ash.Resource.Info.identities/1` has no partial-index
  concept, and the moment the row transitions out of "active" a new
  `origin` claim must be allowed again. `Valea.Mail.Store.create_pending_op/1`
  turns a violation of that index into `{:error, :duplicate_active}`.
  """
  use Ash.Resource,
    domain: Valea.Mail.Store,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "mail_pending_ops"
    repo Valea.Repo
    # Hand-migrated table — see the identical comment on
    # `Valea.Mail.Store.SyncState`'s `sqlite` block.
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :id,
        :kind,
        :account,
        :source_folder,
        :target_folder,
        :uid,
        :source_uidvalidity,
        :dest_watermark,
        :dest_uidvalidity,
        :message_id,
        :msg_id,
        :origin,
        :spool_path,
        :payload_sha256,
        :state,
        :error,
        :inserted_at,
        :updated_at
      ]
    end

    update :transition do
      accept [:state, :error, :uid, :dest_watermark, :dest_uidvalidity, :updated_at]
    end
  end

  attributes do
    # `allow_nil? false` on id/kind/account/origin/state mirrors the DB's
    # `null: false` on these columns (see the create_mail_tables migration) —
    # the constraint fails at the Ash changeset boundary rather than only at
    # the SQLite layer. In-scope hygiene flagged in the PendingOp review.
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :account, :string, allow_nil?: false, public?: true
    attribute :source_folder, :string, public?: true
    attribute :target_folder, :string, public?: true
    attribute :uid, :integer, public?: true
    attribute :source_uidvalidity, :integer, public?: true
    attribute :dest_watermark, :integer, public?: true
    attribute :dest_uidvalidity, :integer, public?: true
    attribute :message_id, :string, public?: true
    attribute :msg_id, :string, public?: true
    attribute :origin, :string, allow_nil?: false, public?: true
    attribute :spool_path, :string, public?: true
    attribute :payload_sha256, :string, public?: true
    attribute :state, :string, allow_nil?: false, public?: true
    attribute :error, :string, public?: true
    attribute :inserted_at, :string, public?: true
    attribute :updated_at, :string, public?: true
  end
end
