defmodule Valea.Repo.Migrations.CreateScheduleTables do
  @moduledoc """
  The scheduler's run-state tables (tasks+schedules spec §Scheduler runtime →
  Persisted state). Hand-migrated (no ash_sqlite codegen/snapshots) — see the
  `migrate? false` comment on `Valea.Schedules.Store.State`.

  Neither table is cache. `schedule_state` holds the anchors that decide what
  fires: losing it silently re-registers every schedule (which, by the reset
  rule, means "first fire at the next future slot" — safe, but the run history
  loses its thread), and `schedule_runs` is the only record that a scheduled
  run ever happened. `schedules.json` is the source of truth for *definitions*;
  these tables are the source of truth for *what has already been consumed*.

    * `schedule_state` — one row per `(icm_id, schedule_id)`, where `icm_id` is
      the ICM's `manifest.id` (the identity that survives a mount rename or
      re-add — the mount key is never the key). The composite **primary key**
      IS the composite unique index the upsert conflicts on: SQLite implements
      a non-`INTEGER` primary key as a unique index, so `ON CONFLICT (icm_id,
      schedule_id)` has its target without a second, redundant index over the
      same two columns.
    * `schedule_runs` — one row per fire/skip event, `id` an opaque UUID.
      Deliberately **no foreign key** to `schedule_state`: run records outlive
      the schedule they came from (a deleted schedule keeps its history, spec
      §Run lifecycle) and are keyed by `(icm_id, schedule_id)` alone, so a
      tombstoned — or later hard-removed — state row can never cascade them
      away. `mount_key` rides along as display metadata for rows whose mount
      has since been renamed.

  Timestamps are `utc_datetime` (second precision, UTC): `slot`/
  `last_attempted_slot` are minute-granular by construction (cron's finest
  field is the minute), and `fired_at`/`first_seen_at`/`deleted_at` never need
  finer than a second. `output` is `:text` and capped by the WRITER (spec
  §Command payloads) — the schema puts no ceiling on it.
  """

  use Ecto.Migration

  def up do
    create table(:schedule_state, primary_key: false) do
      add :icm_id, :string, primary_key: true, null: false
      add :schedule_id, :string, primary_key: true, null: false
      add :fingerprint, :string
      add :first_seen_at, :utc_datetime
      add :last_attempted_slot, :utc_datetime
      add :deleted_at, :utc_datetime
    end

    create table(:schedule_runs, primary_key: false) do
      add :id, :string, primary_key: true, null: false
      add :icm_id, :string, null: false
      add :schedule_id, :string, null: false
      add :fingerprint, :string
      add :slot, :utc_datetime
      add :fired_at, :utc_datetime
      add :trigger, :string
      add :kind, :string
      add :outcome, :string
      add :duration_ms, :integer
      add :session_id, :string
      add :output, :text
      add :coalesced_count, :integer
      add :mount_key, :string
    end

    # The history read (`runs/3`: one schedule, newest `fired_at` first) is the
    # hot query — it backs both the schedule detail view and the scheduler's
    # own "is the previous run still live?" lookup.
    create index(:schedule_runs, [:icm_id, :schedule_id, :fired_at])
  end

  def down do
    drop index(:schedule_runs, [:icm_id, :schedule_id, :fired_at])
    drop table(:schedule_runs)
    drop table(:schedule_state)
  end
end
