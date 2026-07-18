defmodule Valea.Calendar.Store do
  @moduledoc """
  The calendar sync engine's SQLite index — `Valea.Repo` (per-workspace,
  `AshSqlite.DataLayer`) backed by two hand-migrated tables (calendar
  spec §Index):

    * `calendar_occurrences` (`Occurrence`) — one row per expanded
      occurrence of an EXTERNAL source's VEVENT within its window (valea
      events are read live from their files at query time, never
      indexed).
    * `calendar_sync_state` (`SyncState`) — per-source conditional-GET
      validators, diagnostics, and the `derived_rev` derive marker.

  Both tables are PURE CACHE, rebuildable from `sources/calendar/`
  (`feed.ics` + a refetch) — losing `app.sqlite` must never lose data.
  No `AshTypescript` extension — internal-only, never exposed over RPC.
  The resources stay deliberately minimal (the `Valea.Mail.Store`
  posture); this task-brief-shaped API is hand-written on top of them.

  `replace_source!/5` is the engine's derive commit: ONE SQLite
  transaction deletes the source's rows, inserts the fresh expansion, and
  upserts the sync row with the new `derived_rev` — so `derived_rev`
  matches the occurrence rows if and only if the derive completed, which
  is what Task 3's marker check keys on. Queries meanwhile see the
  previous committed rows until the transaction commits — never a
  half-written mixture.
  """
  use Ash.Domain

  require Ash.Query

  alias Valea.Calendar.Store.Occurrence
  alias Valea.Calendar.Store.SyncState

  resources do
    resource Occurrence
    resource SyncState
  end

  @doc """
  Transactionally replaces `slug`'s mirror in the index: deletes its
  occurrence rows, inserts `rows` (maps with `uid`, `all_day`,
  `occ_start`, `occ_end`, `summary`, `location`, `status`, `view_path`),
  and upserts the sync row (`etag`/`last_modified`/`last_sync_at`/
  `derived_rev`, clearing `last_error`). All-or-nothing: any failure
  rolls the whole replace back, leaving the previous mirror intact.
  """
  @spec replace_source!(String.t(), [map()], String.t(), String.t() | nil, String.t() | nil) ::
          :ok
  def replace_source!(slug, rows, derived_rev, etag, last_modified)
      when is_binary(slug) and is_list(rows) and is_binary(derived_rev) do
    {:ok, :ok} =
      Valea.Repo.transaction(fn ->
        delete_rows(slug)

        Enum.each(rows, fn row ->
          Occurrence
          |> Ash.Changeset.for_create(:create, Map.put(row, :source, slug))
          |> Ash.create!()
        end)

        SyncState
        |> Ash.Changeset.for_create(:upsert, %{
          source: slug,
          etag: etag,
          last_modified: last_modified,
          last_sync_at: now_iso8601(),
          last_error: nil,
          derived_rev: derived_rev
        })
        |> Ash.create!()

        :ok
      end)

    :ok
  end

  @doc "The derive marker for `slug`, or `nil` before any completed derive."
  @spec derived_rev(String.t()) :: String.t() | nil
  def derived_rev(slug) when is_binary(slug) do
    case sync_row(slug) do
      nil -> nil
      row -> row.derived_rev
    end
  end

  @doc """
  Records a failed pass: sets `last_error` ONLY, leaving the mirror
  (occurrence rows) and every other sync column untouched — read-modify-
  write over the existing row, or a fresh row carrying just the error
  when the source has never synced.
  """
  @spec mark_error(String.t(), String.t()) :: :ok
  def mark_error(slug, reason) when is_binary(slug) and is_binary(reason) do
    existing =
      case sync_row(slug) do
        nil -> %{}
        row -> sync_row_map(row)
      end

    SyncState
    |> Ash.Changeset.for_create(
      :upsert,
      existing |> Map.merge(%{source: slug, last_error: reason})
    )
    |> Ash.create!()

    :ok
  end

  @doc "Purges `slug` from the index entirely: occurrence rows AND sync state (the purge-RPC path)."
  @spec clear_source!(String.t()) :: :ok
  def clear_source!(slug) when is_binary(slug) do
    {:ok, :ok} =
      Valea.Repo.transaction(fn ->
        delete_rows(slug)

        SyncState
        |> Ash.Query.filter(source == ^slug)
        |> Ash.bulk_destroy!(:destroy, %{})

        :ok
      end)

    :ok
  end

  @doc """
  Every occurrence row (all sources) overlapping the query window, with
  the endpoints matched per their `all_day` tag (spec §Index / the
  `list_calendar_events` overlap rule):

      (all_day = 0 AND occ_start < utc_end AND occ_end > utc_start)
      OR (all_day = 1 AND occ_start < to_date AND occ_end > from_date)

  Timed instants are `YYYY-MM-DDTHH:MM:SSZ`, all-day dates `YYYY-MM-DD`
  with `occ_end` exclusive — both compare correctly as strings. Ordered
  by `occ_start` for determinism; chronological ordering IN a display
  zone is the RPC layer's job.
  """
  @spec occurrences_overlapping(String.t(), String.t(), String.t(), String.t()) :: [map()]
  def occurrences_overlapping(utc_start, utc_end, from_date, to_date)
      when is_binary(utc_start) and is_binary(utc_end) and is_binary(from_date) and
             is_binary(to_date) do
    Occurrence
    |> Ash.Query.filter(
      (all_day == false and occ_start < ^utc_end and occ_end > ^utc_start) or
        (all_day == true and occ_start < ^to_date and occ_end > ^from_date)
    )
    |> Ash.Query.sort(occ_start: :asc)
    |> Ash.read!()
    |> Enum.map(&occurrence_map/1)
  end

  @doc "The sync row for `slug` as a plain map, or `nil` when it has never synced."
  @spec sync_meta(String.t()) ::
          %{
            etag: String.t() | nil,
            last_modified: String.t() | nil,
            last_sync_at: String.t() | nil,
            last_error: String.t() | nil
          }
          | nil
  def sync_meta(slug) when is_binary(slug) do
    case sync_row(slug) do
      nil ->
        nil

      row ->
        %{
          etag: row.etag,
          last_modified: row.last_modified,
          last_sync_at: row.last_sync_at,
          last_error: row.last_error
        }
    end
  end

  @doc "How many occurrence rows `slug` currently has in the index."
  @spec occurrence_count(String.t()) :: non_neg_integer()
  def occurrence_count(slug) when is_binary(slug) do
    Occurrence
    |> Ash.Query.filter(source == ^slug)
    |> Ash.count!()
  end

  # -- internals --------------------------------------------------------------

  defp delete_rows(slug) do
    Occurrence
    |> Ash.Query.filter(source == ^slug)
    |> Ash.bulk_destroy!(:destroy, %{})
  end

  defp sync_row(slug) do
    case Ash.get(SyncState, %{source: slug}) do
      {:ok, row} -> row
      {:error, _not_found} -> nil
    end
  end

  defp sync_row_map(row) do
    %{
      source: row.source,
      etag: row.etag,
      last_modified: row.last_modified,
      last_sync_at: row.last_sync_at,
      last_error: row.last_error,
      derived_rev: row.derived_rev
    }
  end

  defp occurrence_map(row) do
    %{
      source: row.source,
      uid: row.uid,
      all_day: row.all_day,
      occ_start: row.occ_start,
      occ_end: row.occ_end,
      summary: row.summary,
      location: row.location,
      status: row.status,
      view_path: row.view_path
    }
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
