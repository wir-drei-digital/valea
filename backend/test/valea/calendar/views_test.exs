defmodule Valea.Calendar.ViewsTest do
  use ExUnit.Case, async: true

  alias Valea.Calendar.Ics
  alias Valea.Calendar.Source
  alias Valea.Calendar.Views

  @window {~D[2026-07-01], ~D[2026-08-01]}
  @zone "Etc/UTC"
  @rev "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:Etc/UTC:2026-07-01:2026-08-01"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-cal-views-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    source_dir = Path.join(dir, "work")
    File.mkdir_p!(source_dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{source_dir: source_dir}
  end

  # -- fixtures ---------------------------------------------------------------

  defp ics(vevents) do
    (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Valea Test//EN"] ++
       List.flatten(vevents) ++ ["END:VCALENDAR"])
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp vevent(props), do: ["BEGIN:VEVENT"] ++ props ++ ["END:VEVENT"]

  defp feed!(vevents) do
    {:ok, feed} = Ics.parse(ics(vevents))
    feed
  end

  defp rebuild!(source_dir, feed, opts \\ []) do
    Views.rebuild!(
      source_dir,
      Keyword.get(opts, :slug, "work"),
      feed,
      Keyword.get(opts, :rev, @rev),
      Keyword.get(opts, :window, @window),
      Keyword.get(opts, :zone, @zone)
    )
  end

  defp view_path(source_dir, slug, uid, rid) do
    Path.join([source_dir, "views", "events", Ics.view_id(slug, uid, rid) <> ".md"])
  end

  defp view_rel_path(slug, uid, rid) do
    Path.join([
      "sources",
      "calendar",
      slug,
      "views",
      "events",
      Ics.view_id(slug, uid, rid) <> ".md"
    ])
  end

  # -- view frontmatter (exact schema) ---------------------------------------

  test "a supported timed master view carries the exact common frontmatter (no unsupported key)",
       %{source_dir: source_dir} do
    feed =
      feed!([
        vevent([
          "UID:a@x",
          "DTSTART:20260718T100000Z",
          "DTEND:20260718T110000Z",
          "SUMMARY:One",
          "LOCATION:HQ",
          "DESCRIPTION:Agenda line"
        ])
      ])

    result = rebuild!(source_dir, feed)

    assert result.unsupported_series == 0
    assert result.notices == []

    content = File.read!(view_path(source_dir, "work", "a@x", ""))

    assert content ==
             """
             ---
             uid: "a@x"
             source: "work"
             summary: "One"
             start: "2026-07-18T10:00:00Z"
             end: "2026-07-18T11:00:00Z"
             all_day: false
             location: "HQ"
             status: "confirmed"
             recurring: false
             rrule: ""
             recurrence_id: ""
             ---
             Agenda line
             """
  end

  test "an unsupported series view additionally carries recurrence_unsupported: true and the raw rule",
       %{source_dir: source_dir} do
    feed =
      feed!([
        vevent([
          "UID:u@x",
          "DTSTART:20260706T090000Z",
          "DTEND:20260706T100000Z",
          "SUMMARY:Weekly sync",
          "RRULE:FREQ=YEARLY;BYWEEKNO=2"
        ])
      ])

    result = rebuild!(source_dir, feed)

    # NO index rows for the unsupported series — not even DTSTART.
    assert result.rows == []
    assert result.unsupported_series == 1
    assert Enum.any?(result.notices, &(&1 =~ "u@x"))

    content = File.read!(view_path(source_dir, "work", "u@x", ""))

    assert content ==
             """
             ---
             uid: "u@x"
             source: "work"
             summary: "Weekly sync"
             start: "2026-07-06T09:00:00Z"
             end: "2026-07-06T10:00:00Z"
             all_day: false
             location: ""
             status: "confirmed"
             recurring: true
             rrule: "FREQ=YEARLY;BYWEEKNO=2"
             recurrence_id: ""
             recurrence_unsupported: true
             ---
             """
  end

  test "one file per master plus per-override files at distinct view_id paths, raw recurrence ids",
       %{source_dir: source_dir} do
    feed =
      feed!([
        vevent([
          "UID:r@x",
          "DTSTART:20260706T090000Z",
          "DTEND:20260706T093000Z",
          "SUMMARY:Standup",
          "RRULE:FREQ=DAILY;COUNT=3"
        ]),
        vevent([
          "UID:r@x",
          "RECURRENCE-ID:20260707T090000Z",
          "DTSTART:20260707T100000Z",
          "DTEND:20260707T103000Z",
          "SUMMARY:Standup (moved)"
        ])
      ])

    result = rebuild!(source_dir, feed)

    master_path = view_path(source_dir, "work", "r@x", "")
    override_path = view_path(source_dir, "work", "r@x", "2026-07-07T09:00:00Z")
    assert master_path != override_path
    assert File.exists?(master_path)
    assert File.exists?(override_path)

    master = File.read!(master_path)
    override = File.read!(override_path)

    # The master's recurrence_id is empty; the override carries the RAW value.
    assert master =~ ~s(recurrence_id: "")
    assert master =~ ~s(recurring: true)
    assert master =~ ~s(rrule: "FREQ=DAILY;COUNT=3")
    assert override =~ ~s(recurrence_id: "20260707T090000Z")
    assert override =~ "summary: \"Standup (moved)\""
    refute master =~ "recurrence_unsupported"
    refute override =~ "recurrence_unsupported"

    # Three occurrences; the overridden one carries the override's summary,
    # start, and view_path.
    assert length(result.rows) == 3

    moved = Enum.find(result.rows, &(&1.summary == "Standup (moved)"))
    assert moved.occ_start == "2026-07-07T10:00:00Z"
    assert moved.occ_end == "2026-07-07T10:30:00Z"
    assert moved.view_path == view_rel_path("work", "r@x", "2026-07-07T09:00:00Z")

    regular = Enum.find(result.rows, &(&1.occ_start == "2026-07-06T09:00:00Z"))
    assert regular.summary == "Standup"
    assert regular.view_path == view_rel_path("work", "r@x", "")
  end

  test "all-day events: view and rows use plain dates with an exclusive end", %{
    source_dir: source_dir
  } do
    feed =
      feed!([
        vevent([
          "UID:d@x",
          "DTSTART;VALUE=DATE:20260710",
          "DTEND;VALUE=DATE:20260712",
          "SUMMARY:Offsite"
        ])
      ])

    result = rebuild!(source_dir, feed)

    assert [row] = result.rows
    assert row.all_day == true
    assert row.occ_start == "2026-07-10"
    assert row.occ_end == "2026-07-12"

    content = File.read!(view_path(source_dir, "work", "d@x", ""))
    assert content =~ ~s(start: "2026-07-10")
    assert content =~ ~s(end: "2026-07-12")
    assert content =~ "all_day: true"
  end

  test "an unmatched override renders standalone with a notice", %{source_dir: source_dir} do
    feed =
      feed!([
        vevent([
          "UID:m@x",
          "DTSTART:20260706T090000Z",
          "DTEND:20260706T100000Z",
          "SUMMARY:Solo"
        ]),
        vevent([
          "UID:m@x",
          "RECURRENCE-ID:20260720T090000Z",
          "DTSTART:20260720T110000Z",
          "DTEND:20260720T120000Z",
          "SUMMARY:Orphan"
        ])
      ])

    result = rebuild!(source_dir, feed)

    assert length(result.rows) == 2
    assert Enum.any?(result.rows, &(&1.summary == "Orphan"))
    assert Enum.any?(result.notices, &(&1 =~ "matches no occurrence"))
  end

  test "hostile UIDs never reach a filename", %{source_dir: source_dir} do
    feed =
      feed!([
        vevent([
          "UID:../../etc/passwd",
          "DTSTART:20260718T100000Z",
          "DTEND:20260718T110000Z",
          "SUMMARY:Evil"
        ])
      ])

    rebuild!(source_dir, feed)

    entries = File.ls!(Path.join([source_dir, "views", "events"]))
    assert entries != []
    assert Enum.all?(entries, &Regex.match?(~r/^ev-[0-9a-f]{16}\.md$/, &1))
    refute File.exists?(Path.join([source_dir, "etc"]))
  end

  test "yaml escaping: quotes, backslashes, and control chars in feed text stay inert", %{
    source_dir: source_dir
  } do
    feed =
      feed!([
        vevent([
          "UID:q@x",
          "DTSTART:20260718T100000Z",
          "DTEND:20260718T110000Z",
          ~s(SUMMARY:He said "hi\\, friend" \\\\ done)
        ])
      ])

    rebuild!(source_dir, feed)

    content = File.read!(view_path(source_dir, "work", "q@x", ""))
    assert content =~ ~s(summary: "He said \\"hi, friend\\" \\\\ done")
  end

  # -- .rev and the swap ------------------------------------------------------

  test ".rev is written inside the swapped views dir; current_rev reads it", %{
    source_dir: source_dir
  } do
    assert Views.current_rev(source_dir) == nil

    feed =
      feed!([
        vevent(["UID:a@x", "DTSTART:20260718T100000Z", "DTEND:20260718T110000Z", "SUMMARY:One"])
      ])

    rebuild!(source_dir, feed)

    assert File.read!(Path.join([source_dir, "views", ".rev"])) == @rev
    assert Views.current_rev(source_dir) == @rev
  end

  test "the double-rename replace removes stale views and leaves no tmp/old dirs", %{
    source_dir: source_dir
  } do
    two =
      feed!([
        vevent(["UID:a@x", "DTSTART:20260718T100000Z", "DTEND:20260718T110000Z", "SUMMARY:One"]),
        vevent(["UID:b@x", "DTSTART:20260719T100000Z", "DTEND:20260719T110000Z", "SUMMARY:Two"])
      ])

    rebuild!(source_dir, two)
    assert length(File.ls!(Path.join([source_dir, "views", "events"]))) == 2

    one =
      feed!([
        vevent(["UID:a@x", "DTSTART:20260718T100000Z", "DTEND:20260718T110000Z", "SUMMARY:One"])
      ])

    rebuild!(source_dir, one, rev: "b" <> String.slice(@rev, 1..-1//1))

    entries = File.ls!(Path.join([source_dir, "views", "events"]))
    assert length(entries) == 1
    assert entries == [Ics.view_id("work", "a@x", "") <> ".md"]
    assert Views.current_rev(source_dir) == "b" <> String.slice(@rev, 1..-1//1)

    # No swap debris left behind.
    refute Enum.any?(
             File.ls!(source_dir),
             &(String.starts_with?(&1, "views.tmp-") or String.starts_with?(&1, "views.old-"))
           )
  end

  test "rows carry uid, status, and location from the producing event", %{source_dir: source_dir} do
    feed =
      feed!([
        vevent([
          "UID:t@x",
          "DTSTART:20260718T100000Z",
          "DTEND:20260718T110000Z",
          "SUMMARY:Tentative one",
          "STATUS:TENTATIVE",
          "LOCATION:Room 4"
        ])
      ])

    result = rebuild!(source_dir, feed)

    assert [row] = result.rows
    assert row.uid == "t@x"
    assert row.status == "tentative"
    assert row.location == "Room 4"
    assert row.all_day == false
  end

  test "a cancelled master emits no rows but still writes its view", %{source_dir: source_dir} do
    feed =
      feed!([
        vevent([
          "UID:c@x",
          "DTSTART:20260718T100000Z",
          "DTEND:20260718T110000Z",
          "SUMMARY:Gone",
          "STATUS:CANCELLED"
        ])
      ])

    result = rebuild!(source_dir, feed)

    assert result.rows == []
    assert File.exists?(view_path(source_dir, "work", "c@x", ""))
  end
end

defmodule Valea.Calendar.SourceTest do
  use ExUnit.Case, async: true

  alias Valea.Calendar.Source

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-cal-source-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  @url "https://calendar.google.com/calendar/ical/private-token/basic.ics"

  defp hash16(url) do
    :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  test "an absent .source is claimed with host + first 16 hex of sha256(url)", %{dir: dir} do
    assert Source.verify_or_claim(dir, @url) == :ok

    assert File.read!(Path.join(dir, ".source")) ==
             "calendar.google.com\n" <> hash16(@url) <> "\n"
  end

  test "a present-and-matching .source verifies", %{dir: dir} do
    assert Source.verify_or_claim(dir, @url) == :ok
    assert Source.verify_or_claim(dir, @url) == :ok
  end

  test "a different URL on the same host is an identity mismatch (never overwritten)", %{
    dir: dir
  } do
    assert Source.verify_or_claim(dir, @url) == :ok
    original = File.read!(Path.join(dir, ".source"))

    other = "https://calendar.google.com/calendar/ical/other-token/basic.ics"
    assert Source.verify_or_claim(dir, other) == {:error, :identity_mismatch}
    assert File.read!(Path.join(dir, ".source")) == original
  end

  test "a different host is an identity mismatch", %{dir: dir} do
    assert Source.verify_or_claim(dir, @url) == :ok

    assert Source.verify_or_claim(dir, "https://example.org/feed.ics") ==
             {:error, :identity_mismatch}
  end

  test "an unparseable .source file is a mismatch, never re-claimed", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".source"), "garbage")

    assert Source.verify_or_claim(dir, @url) == {:error, :identity_mismatch}
    assert File.read!(Path.join(dir, ".source")) == "garbage"
  end
end
