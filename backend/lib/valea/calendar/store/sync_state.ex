defmodule Valea.Calendar.Store.SyncState do
  @moduledoc """
  Per-source calendar sync bookkeeping: the conditional-GET validators
  (`etag`, `last_modified`), light diagnostics (`last_sync_at`,
  `last_error`), and `derived_rev` — the derive marker (spec §Index):
  `sha256(snapshot bytes) <> ":" <> host zone <> ":" <> window dates`,
  written ATOMICALLY in the same transaction as the rebuilt occurrence
  rows, so a failed or incomplete derive leaves it mismatched — which is
  exactly what re-triggers the derive on the next pass, 304s included.
  Pure cache: rebuildable from `feed.ics` + a refetch.
  """
  use Ash.Resource,
    domain: Valea.Calendar.Store,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "calendar_sync_state"
    repo Valea.Repo
    # Hand-migrated table — see the identical comment on
    # `Valea.Calendar.Store.Occurrence`'s `sqlite` block.
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true

      accept [:source, :etag, :last_modified, :last_sync_at, :last_error, :derived_rev]

      upsert? true

      upsert_fields [:etag, :last_modified, :last_sync_at, :last_error, :derived_rev]
    end
  end

  attributes do
    attribute :source, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :etag, :string, public?: true
    attribute :last_modified, :string, public?: true
    attribute :last_sync_at, :string, public?: true
    attribute :last_error, :string, public?: true
    attribute :derived_rev, :string, public?: true
  end
end
