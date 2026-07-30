defmodule Valea.Schedules.Store.Run do
  @moduledoc """
  One scheduler event: a fire, a skip, or a consumed-slot record with an
  outcome (tasks+schedules spec §Persisted state → Run records).

  `id` is an opaque UUID, generated on create; it is the handle
  `Valea.Schedules.Store.update_run/2` keys off when the run finishes.

  Rows are keyed by `(icm_id, schedule_id)` and hold **no foreign key** to
  `schedule_state`, deliberately: history survives the schedule's deletion
  (spec §Run lifecycle — "a schedule deleted while its run is in flight: the
  run completes; history is retained") and survives a mount rename. `mount_key`
  is display metadata — the mount the run happened under, for a row whose mount
  has since been renamed — and is never part of the key.

  ## Fields

    * `fingerprint` — the definition that actually ran, so history stays
      readable after the schedule is edited into something else.
    * `slot` — the scheduled instant this run consumed. `fired_at` — when the
      scheduler acted. They differ by the tick latency, and by a lot after a
      coalesced catch-up.
    * `trigger` — `"scheduled"` | `"catchup"` | `"manual"`.
    * `kind` — `"prompt"` | `"command"` (the payload kind).
    * `outcome` — a **free-form string**, not an enum. The tokens the spec
      names are `"running"`, `"completed"`, `"failed"`,
      `"skipped: still running"`, `"interrupted"`, `"timed out"` and
      `"waiting"`; the schema constrains none of them, because outcome text is
      shown to a human and will grow new phrasings. Two of those tokens are
      load-bearing for `Valea.Schedules.Store.notices_since/1`, which matches
      `"waiting"` and `"failed"` by **exact equality** — a writer that
      elaborates the outcome (`"failed: spawn error"`) silently drops out of
      the cockpit notices. Failure detail belongs in `output`.
    * `duration_ms`, `session_id` — filled in at completion; a prompt run's
      session is the ordinary session it ran as.
    * `output` — captured text for a command run. **Capped by the caller**
      (spec §Command payloads: exec-style spawn, allowlisted env, ICM-root cwd,
      timeout, output cap). The store re-caps nothing and stores what it is
      handed verbatim.
    * `coalesced_count` — how many elapsed slots this one record consumed
      (spec §Firing rule step 4/5: several elapsed slots fire once, and a skip
      while the previous run is still live consumes them all with a single
      record). Defaults to `1`, the ordinary single-slot fire.

  `fired_at` defaults to now so history ordering can never contain a `nil`
  `fired_at` hole; the scheduler passes it explicitly. Both instants are
  `:utc_datetime` — UTC, second precision.
  """
  use Ash.Resource,
    domain: Valea.Schedules.Store,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "schedule_runs"
    repo Valea.Repo
    # Hand-migrated — see the identical comment on `Valea.Schedules.Store.State`.
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :id,
        :icm_id,
        :schedule_id,
        :fingerprint,
        :slot,
        :fired_at,
        :trigger,
        :kind,
        :outcome,
        :duration_ms,
        :session_id,
        :output,
        :coalesced_count,
        :mount_key
      ]
    end

    # The completion write, and the only mutation a run record ever takes: the
    # launch columns (`slot`, `trigger`, `fingerprint`, ...) are history and
    # stay immutable.
    update :finish do
      accept [:outcome, :duration_ms, :output]
    end
  end

  attributes do
    attribute :id, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      default: &Ash.UUID.generate/0

    # `allow_nil? false` mirrors the migration's `null: false` on the two key
    # columns, so a missing one fails at the changeset boundary rather than in
    # SQLite.
    attribute :icm_id, :string, allow_nil?: false, public?: true
    attribute :schedule_id, :string, allow_nil?: false, public?: true
    attribute :fingerprint, :string, public?: true
    attribute :slot, :utc_datetime, public?: true
    attribute :fired_at, :utc_datetime, public?: true, default: &DateTime.utc_now/0
    attribute :trigger, :string, public?: true
    attribute :kind, :string, public?: true
    attribute :outcome, :string, public?: true
    attribute :duration_ms, :integer, public?: true
    attribute :session_id, :string, public?: true
    attribute :output, :string, public?: true
    attribute :coalesced_count, :integer, public?: true, default: 1
    attribute :mount_key, :string, public?: true
  end
end
