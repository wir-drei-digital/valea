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
    * `session_id` — the session a prompt run ran as. Not knowable at create:
      the record is written BEFORE the spawn (so a crash in between still
      leaves evidence the fire happened), and the id is attached by
      `Valea.Schedules.Store.update_run/2` the moment the spawn returns. That
      is why `:progress` accepts it — see the action's own comment.
    * `duration_ms` — filled in at completion.
    * `output` — captured text for a command run. **Capped by the caller**
      (spec §Command payloads: exec-style spawn, allowlisted env, ICM-root cwd,
      timeout, output cap). The store re-caps nothing and stores what it is
      handed verbatim.
    * `coalesced_count` — how many elapsed slots this one record consumed
      (spec §Firing rule step 4/5: several elapsed slots fire once, and a skip
      while the previous run is still live consumes them all with a single
      record). Defaults to `1`, the ordinary single-slot fire.

  `fired_at` is **required** and defaults to now — the scheduler passes it
  explicitly, and the default only covers an omitted key. `allow_nil? false`
  is what closes the gap the default alone leaves open: a `default:` applies
  when a key is ABSENT, never when it is present and `nil`, so
  `record_run(%{fired_at: nil, outcome: "failed"})` would otherwise store a
  NULL — and a NULL fails `fired_at >= ?`, leaving that failed run in the
  history list but permanently invisible to
  `Valea.Schedules.Store.notices_since/1`. A dropped failure notice is the one
  outcome the spec's scheduled-session visibility rule exists to prevent, so
  the nil raises instead. `slot` stays nullable — a manual fire consumes no
  slot. Both instants are `:utc_datetime`, UTC, second precision.
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
    # No `:destroy`: nothing in this domain deletes a run record — history
    # outlives the schedule by design, and a retention sweep, if one ever
    # lands, can add the action then.
    defaults [:read]

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

    # The only mutation a run record ever takes: filling in what was not
    # knowable at launch. `session_id` lands right after the spawn returns,
    # `outcome`/`duration_ms`/`output` at completion — one action rather than
    # two, because both writes are the same "this run progressed" fact and
    # neither may touch the launch columns (`slot`, `trigger`, `fingerprint`,
    # `kind`, `coalesced_count`, `mount_key`), which are history and stay
    # immutable.
    update :progress do
      accept [:outcome, :duration_ms, :output, :session_id]
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
    # `allow_nil? false` AND a default — see the moduledoc: the default covers
    # an omitted key, `allow_nil? false` covers an explicit `nil`, and only
    # both together keep a NULL out of the notices' window bound.
    attribute :fired_at, :utc_datetime,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0

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
