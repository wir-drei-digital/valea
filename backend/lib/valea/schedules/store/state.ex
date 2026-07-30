defmodule Valea.Schedules.Store.State do
  @moduledoc """
  Per-schedule scheduler state: the anchors and the fingerprint that decide
  what fires (tasks+schedules spec §Persisted state).

  Keyed by `(icm_id, schedule_id)`, where `icm_id` is the ICM's `manifest.id`
  — the identity that survives a mount rename or re-add. The mount key is
  display metadata on run records, never part of this key.

  The columns, and why each one exists:

    * `fingerprint` — SHA-256 over the entry's **execution-relevant fields
      only** (`Valea.Schedules.Entry.fingerprint/1`: `catchup`, `cron`,
      `payload`, `timezone`). A title fix or a pause toggle deliberately does
      not change it, so neither suppresses a due fire nor resets the anchor.
    * `first_seen_at` — UTC instant this fingerprint was first observed. The
      floor for the due test, which is what makes a newly registered schedule
      fire at its next *future* slot instead of instantly.
    * `last_attempted_slot` — UTC instant of the most recent **consumed** slot
      (fired, skipped, fast-forwarded, or consumed while paused). The anchor.
      It is **monotonic — it must never move backward**; the store persists
      whatever it is handed, and the `max/2` that enforces monotonicity lives
      in the scheduler that writes it (spec §Catch-up). Nothing that matters
      lives only in process state: there is no in-memory tick watermark.
    * `deleted_at` — tombstone, set when a *parseable* `schedules.json` no
      longer contains the id (an unreadable file is never read as deletion —
      fail-safe). A reappearance, byte-identical included, resets
      `first_seen_at`/`last_attempted_slot` to now and clears the tombstone in
      one write, so delete-recreate never inherits old anchors.

  Timestamps are `:utc_datetime` — UTC, second precision. Slots are
  minute-granular by construction (cron's finest field is the minute), so the
  truncation costs the anchor nothing; it only drops sub-second noise from
  `first_seen_at`, and it drops it *downward*, which can never conjure a slot
  the entry did not already exist for.

  ## Why no attribute carries a `default:` — and why `put_state/3` merges anyway

  Nothing here has a `default:`, and that alone is what would make a bare
  upsert safe today: an attribute the changeset never sets, and that has no
  default, does not enter the INSERT column list at all, so
  `ON CONFLICT ... DO UPDATE SET` only touches the columns the caller actually
  passed. Verified against the emitted SQL, not assumed.

  `Valea.Schedules.Store.put_state/3` merges `attrs` over the stored row
  regardless. That is **forward-insurance, not a fix for a bug present today**:
  the moment any of these four columns grows a `default:`, an omitted key
  starts arriving as that default, enters the SET list, and silently overwrites
  what the row held — which is exactly the live bug
  `Valea.Mail.Store.put_sync_state/3` documents, where `backfill_complete` and
  `held` do carry `default: false` and a partial write resets whichever flag it
  did not mention. Adding a default here should be harmless; the merge is what
  makes it so. A test asserts the emitted SET list names all four mutable
  columns, so removing the merge as "dead code" fails loudly rather than
  quietly re-arming that bug.
  """
  use Ash.Resource,
    domain: Valea.Schedules.Store,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "schedule_state"
    repo Valea.Repo
    # Hand-migrated (`20260730000001_create_schedule_tables.exs`) — never
    # generated. `migrate? false` excludes the table from
    # `AshSqlite.MigrationGenerator`'s snapshot diff, which both
    # `mix ash.codegen` and `AshPhoenix.Plug.CheckCodegenStatus` (the dev-only
    # plug that reruns that diff on every request) walk; without it, dev boots
    # 500 with `Ash.Error.Framework.PendingCodegen` on the first request. Same
    # reasoning as every `Valea.Mail.Store.*` resource.
    migrate? false
  end

  actions do
    # No `:destroy`: deletion is the `deleted_at` tombstone, and the
    # reconciler needs the tombstoned row to tell a reappearance from a first
    # registration. Nothing in this domain hard-deletes a state row.
    defaults [:read]

    create :upsert do
      primary? true

      accept [
        :icm_id,
        :schedule_id,
        :fingerprint,
        :first_seen_at,
        :last_attempted_slot,
        :deleted_at
      ]

      upsert? true

      # The conflict target is the composite primary key, which SQLite
      # implements as a unique index (see the migration moduledoc).
      upsert_fields [:fingerprint, :first_seen_at, :last_attempted_slot, :deleted_at]
    end
  end

  attributes do
    attribute :icm_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :schedule_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :fingerprint, :string, public?: true
    attribute :first_seen_at, :utc_datetime, public?: true
    attribute :last_attempted_slot, :utc_datetime, public?: true
    attribute :deleted_at, :utc_datetime, public?: true
  end
end
