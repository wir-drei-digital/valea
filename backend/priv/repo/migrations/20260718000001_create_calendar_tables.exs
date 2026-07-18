defmodule Valea.Repo.Migrations.CreateCalendarTables do
  @moduledoc """
  Calendar index tables (`calendar_occurrences` + `calendar_sync_state`,
  calendar spec §Index). Hand-migrated (no ash_sqlite codegen/snapshots)
  — see the `migrate? false` comment on each `Valea.Calendar.Store.*`
  resource. Both tables are pure cache, rebuildable from
  `sources/calendar/` (`feed.ics` snapshots + a refetch).
  """

  use Ecto.Migration

  def up do
    create table(:calendar_occurrences, primary_key: false) do
      add :id, :string, primary_key: true, null: false
      add :source, :string, null: false
      add :uid, :string
      add :all_day, :boolean, null: false, default: false
      add :occ_start, :string, null: false
      add :occ_end, :string, null: false
      add :summary, :string
      add :location, :string
      add :status, :string
      add :view_path, :string
    end

    create index(:calendar_occurrences, [:occ_start, :occ_end])
    create index(:calendar_occurrences, [:source])

    create table(:calendar_sync_state, primary_key: false) do
      add :source, :string, primary_key: true, null: false
      add :etag, :string
      add :last_modified, :string
      add :last_sync_at, :string
      add :last_error, :string
      add :derived_rev, :string
    end
  end

  def down do
    drop index(:calendar_occurrences, [:source])
    drop index(:calendar_occurrences, [:occ_start, :occ_end])
    drop table(:calendar_occurrences)
    drop table(:calendar_sync_state)
  end
end
