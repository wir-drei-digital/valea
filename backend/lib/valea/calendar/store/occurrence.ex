defmodule Valea.Calendar.Store.Occurrence do
  @moduledoc """
  One expanded occurrence of one EXTERNAL source's VEVENT within that
  source's configured window — the calendar index rows `list_events`
  queries (valea events are read live from their files, never indexed).
  Pure cache: rebuilt wholesale from the committed `feed.ics` snapshot on
  every derive (`Valea.Calendar.Store.replace_source!/5`), never the
  source of truth.

  The endpoints are TAGGED by `all_day` (spec §Index): timed rows store
  UTC ISO instants (`YYYY-MM-DDTHH:MM:SSZ`); all-day rows store plain ISO
  dates (`YYYY-MM-DD`) with `occ_end` EXCLUSIVE — an all-day date is
  never encoded as a UTC midnight (a negative-offset host would shift it
  a day).

  Rows are insert-only within a per-source transactional replace, so the
  primary key is a surrogate id (external UIDs are arbitrary bytes and a
  pathological feed could repeat a (uid, occ_start) pair — a natural key
  would turn that into a failed derive).
  """
  use Ash.Resource,
    domain: Valea.Calendar.Store,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "calendar_occurrences"
    repo Valea.Repo
    # This table is hand-migrated (see the migration,
    # `create_calendar_tables.exs`) — never generated. `migrate? false`
    # excludes it from `AshSqlite.MigrationGenerator`'s snapshot diff,
    # which is what both `mix ash.codegen` and
    # `AshPhoenix.Plug.CheckCodegenStatus` (the dev-only endpoint plug
    # that reruns that diff on every request) walk. Without this, dev
    # boots 500 with `Ash.Error.Framework.PendingCodegen` on the very
    # first request, and running codegen would emit a second, redundant
    # migration racing the hand-written one against an already-migrated
    # table.
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :source,
        :uid,
        :all_day,
        :occ_start,
        :occ_end,
        :summary,
        :location,
        :status,
        :view_path
      ]
    end
  end

  attributes do
    attribute :id, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      default: &Ash.UUID.generate/0

    attribute :source, :string, allow_nil?: false, public?: true
    attribute :uid, :string, public?: true
    attribute :all_day, :boolean, allow_nil?: false, default: false, public?: true
    attribute :occ_start, :string, allow_nil?: false, public?: true
    attribute :occ_end, :string, allow_nil?: false, public?: true
    attribute :summary, :string, public?: true
    attribute :location, :string, public?: true
    attribute :status, :string, public?: true
    attribute :view_path, :string, public?: true
  end
end
