defmodule Valea.Calendar.StoreTest do
  use ExUnit.Case, async: false

  alias Valea.Calendar.Store

  defp row(overrides) do
    Map.merge(
      %{
        uid: "uid-1@example.com",
        all_day: false,
        occ_start: "2026-07-10T10:00:00Z",
        occ_end: "2026-07-10T11:00:00Z",
        summary: "Standup",
        location: nil,
        status: "confirmed",
        view_path: "sources/calendar/work/views/events/ev-0000000000000000.md"
      },
      overrides
    )
  end

  # Focused unit tests per the task brief (the mail store_test posture):
  # start `Valea.Repo` directly against a tmp `app.sqlite` + run the real
  # migrations, rather than going through the full workspace open lifecycle.
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-cal-store-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    # pool_size: 1 — a single sequential test process needs no concurrent
    # connections, and it sidesteps a startup race where multiple pool
    # workers open the brand-new sqlite file while the migration is still
    # running its DDL (logs a transient, harmless "database is locked").
    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    # `ignore_module_conflict` avoids a "redefining module" warning: every
    # test recompiles the same migration files against a brand-new sqlite db.
    previous_compiler_options = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous_compiler_options)

    on_exit(fn -> File.rm_rf!(dir) end)

    :ok
  end

  describe "replace_source!/5" do
    test "installs rows and sync meta in one operation" do
      rows = [
        row(%{}),
        row(%{
          uid: "uid-2@example.com",
          occ_start: "2026-07-11T09:00:00Z",
          occ_end: "2026-07-11T10:00:00Z"
        })
      ]

      assert :ok =
               Store.replace_source!(
                 "work",
                 rows,
                 "rev-1",
                 "\"e1\"",
                 "Sat, 18 Jul 2026 08:00:00 GMT"
               )

      assert Store.occurrence_count("work") == 2
      assert Store.derived_rev("work") == "rev-1"

      meta = Store.sync_meta("work")
      assert meta.etag == "\"e1\""
      assert meta.last_modified == "Sat, 18 Jul 2026 08:00:00 GMT"
      assert meta.last_error == nil
      assert is_binary(meta.last_sync_at)
    end

    test "replaces the previous mirror wholesale, leaving other sources untouched" do
      :ok =
        Store.replace_source!(
          "work",
          [row(%{uid: "old-1"}), row(%{uid: "old-2"})],
          "rev-1",
          nil,
          nil
        )

      :ok = Store.replace_source!("home", [row(%{uid: "home-1"})], "rev-h", nil, nil)

      :ok = Store.replace_source!("work", [row(%{uid: "new-1"})], "rev-2", "\"e2\"", nil)

      assert Store.occurrence_count("work") == 1
      assert Store.occurrence_count("home") == 1
      assert Store.derived_rev("work") == "rev-2"
      assert Store.derived_rev("home") == "rev-h"

      uids =
        Store.occurrences_overlapping(
          "2026-07-01T00:00:00Z",
          "2026-08-01T00:00:00Z",
          "2026-07-01",
          "2026-08-01"
        )
        |> Enum.map(& &1.uid)
        |> Enum.sort()

      assert uids == ["home-1", "new-1"]
    end

    test "clears a previous last_error" do
      :ok = Store.replace_source!("work", [row(%{})], "rev-1", nil, nil)
      :ok = Store.mark_error("work", "boom")
      assert Store.sync_meta("work").last_error == "boom"

      :ok = Store.replace_source!("work", [row(%{})], "rev-2", nil, nil)
      assert Store.sync_meta("work").last_error == nil
    end

    test "is transactional: a bad row rolls back the whole replace" do
      :ok =
        Store.replace_source!(
          "work",
          [row(%{uid: "keep-1"}), row(%{uid: "keep-2"})],
          "rev-1",
          "\"e1\"",
          nil
        )

      bad = [row(%{uid: "new-1"}), row(%{uid: "new-2", occ_start: nil})]

      assert_raise Ash.Error.Invalid, fn ->
        Store.replace_source!("work", bad, "rev-2", "\"e2\"", nil)
      end

      # The previous mirror survives in full — rows AND sync meta.
      assert Store.occurrence_count("work") == 2
      assert Store.derived_rev("work") == "rev-1"
      assert Store.sync_meta("work").etag == "\"e1\""
    end
  end

  describe "derived_rev/1" do
    test "is nil before any derive and round-trips after" do
      assert Store.derived_rev("work") == nil

      :ok =
        Store.replace_source!("work", [], "abc123:Europe/Zurich:2026-06-18:2027-07-18", nil, nil)

      assert Store.derived_rev("work") == "abc123:Europe/Zurich:2026-06-18:2027-07-18"
    end
  end

  describe "mark_error/2" do
    test "sets last_error and leaves the mirror and sync meta untouched" do
      :ok = Store.replace_source!("work", [row(%{})], "rev-1", "\"e1\"", "lm-1")
      before = Store.sync_meta("work")

      assert :ok = Store.mark_error("work", "tls")

      meta = Store.sync_meta("work")
      assert meta.last_error == "tls"
      assert meta.etag == "\"e1\""
      assert meta.last_modified == "lm-1"
      assert meta.last_sync_at == before.last_sync_at
      assert Store.derived_rev("work") == "rev-1"
      assert Store.occurrence_count("work") == 1
    end

    test "creates the sync row when none exists yet" do
      assert Store.sync_meta("work") == nil
      assert :ok = Store.mark_error("work", "timeout")

      meta = Store.sync_meta("work")
      assert meta.last_error == "timeout"
      assert meta.etag == nil
      assert Store.occurrence_count("work") == 0
    end
  end

  describe "clear_source!/1" do
    test "purges rows and sync state for one source only" do
      :ok = Store.replace_source!("work", [row(%{})], "rev-1", nil, nil)
      :ok = Store.replace_source!("home", [row(%{uid: "home-1"})], "rev-h", nil, nil)

      assert :ok = Store.clear_source!("work")

      assert Store.occurrence_count("work") == 0
      assert Store.sync_meta("work") == nil
      assert Store.derived_rev("work") == nil
      assert Store.occurrence_count("home") == 1
      assert Store.sync_meta("home") != nil
    end

    test "is a no-op on an unknown source" do
      assert :ok = Store.clear_source!("ghost")
    end
  end

  describe "occurrences_overlapping/4" do
    # Query window: timed [10:00, 12:00) UTC on 2026-07-10; all-day [2026-07-10, 2026-07-11).
    @utc_start "2026-07-10T10:00:00Z"
    @utc_end "2026-07-10T12:00:00Z"
    @from "2026-07-10"
    @to "2026-07-11"

    defp seed_truth_table do
      rows = [
        # inside the window
        row(%{
          uid: "t-inside",
          occ_start: "2026-07-10T10:30:00Z",
          occ_end: "2026-07-10T11:00:00Z"
        }),
        # straddles the window start (overlap, not start-filter)
        row(%{
          uid: "t-straddle-start",
          occ_start: "2026-07-10T09:00:00Z",
          occ_end: "2026-07-10T10:30:00Z"
        }),
        # straddles the window end
        row(%{
          uid: "t-straddle-end",
          occ_start: "2026-07-10T11:30:00Z",
          occ_end: "2026-07-10T13:00:00Z"
        }),
        # spans the whole window
        row(%{
          uid: "t-spans",
          occ_start: "2026-07-10T08:00:00Z",
          occ_end: "2026-07-10T14:00:00Z"
        }),
        # ends exactly at the window start — excluded (occ_end > utc_start is strict)
        row(%{
          uid: "t-ends-at-start",
          occ_start: "2026-07-10T09:00:00Z",
          occ_end: "2026-07-10T10:00:00Z"
        }),
        # starts exactly at the window end — excluded (occ_start < utc_end is strict)
        row(%{
          uid: "t-starts-at-end",
          occ_start: "2026-07-10T12:00:00Z",
          occ_end: "2026-07-10T13:00:00Z"
        }),
        # one-day all-day event on the queried day
        row(%{uid: "a-on-day", all_day: true, occ_start: "2026-07-10", occ_end: "2026-07-11"}),
        # multi-day all-day event straddling the queried day
        row(%{uid: "a-straddles", all_day: true, occ_start: "2026-07-09", occ_end: "2026-07-12"}),
        # all-day event whose EXCLUSIVE end is the queried day — excluded
        row(%{
          uid: "a-ends-before",
          all_day: true,
          occ_start: "2026-07-08",
          occ_end: "2026-07-10"
        }),
        # all-day event starting at the exclusive query end — excluded
        row(%{
          uid: "a-starts-at-to",
          all_day: true,
          occ_start: "2026-07-11",
          occ_end: "2026-07-12"
        })
      ]

      :ok = Store.replace_source!("work", rows, "rev-1", nil, nil)
    end

    test "timed rows match by instant overlap, all-day rows by exclusive date overlap" do
      seed_truth_table()

      uids =
        Store.occurrences_overlapping(@utc_start, @utc_end, @from, @to)
        |> Enum.map(& &1.uid)
        |> Enum.sort()

      assert uids == [
               "a-on-day",
               "a-straddles",
               "t-inside",
               "t-spans",
               "t-straddle-end",
               "t-straddle-start"
             ]
    end

    test "an all-day row never leaks into a purely-timed match window and vice versa" do
      # The timed window covers the whole day, the date window covers none of it.
      seed_truth_table()

      uids =
        Store.occurrences_overlapping(
          "2026-07-10T00:00:00Z",
          "2026-07-11T00:00:00Z",
          "2026-01-01",
          "2026-01-02"
        )
        |> Enum.map(& &1.uid)

      refute Enum.any?(uids, &String.starts_with?(&1, "a-"))
      assert Enum.any?(uids, &String.starts_with?(&1, "t-"))

      # And the inverse: date window only.
      uids =
        Store.occurrences_overlapping(
          "2027-01-01T00:00:00Z",
          "2027-01-02T00:00:00Z",
          @from,
          @to
        )
        |> Enum.map(& &1.uid)

      assert Enum.sort(uids) == ["a-on-day", "a-straddles"]
    end

    test "rows carry the full column set" do
      :ok = Store.replace_source!("work", [row(%{location: "HQ"})], "rev-1", nil, nil)

      assert [occ] =
               Store.occurrences_overlapping(@utc_start, @utc_end, @from, @to)

      assert occ.source == "work"
      assert occ.uid == "uid-1@example.com"
      assert occ.all_day == false
      assert occ.occ_start == "2026-07-10T10:00:00Z"
      assert occ.occ_end == "2026-07-10T11:00:00Z"
      assert occ.summary == "Standup"
      assert occ.location == "HQ"
      assert occ.status == "confirmed"
      assert occ.view_path == "sources/calendar/work/views/events/ev-0000000000000000.md"
    end
  end

  describe "sync_meta/1 and occurrence_count/1" do
    test "sync_meta is nil for an unknown source" do
      assert Store.sync_meta("ghost") == nil
    end

    test "occurrence_count is 0 for an unknown source" do
      assert Store.occurrence_count("ghost") == 0
    end
  end
end
