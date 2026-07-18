defmodule Valea.Calendar.IcsTest do
  use ExUnit.Case, async: true

  alias Valea.Calendar.Ics
  alias Valea.Calendar.Ics.{Event, Feed}
  alias Valea.Calendar.WindowsZones

  @fixtures Path.expand("../../fixtures/ics", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp feed!(text) do
    assert {:ok, %Feed{} = feed} = Ics.parse(text)
    feed
  end

  defp cal(inner), do: "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" <> inner <> "END:VCALENDAR\r\n"

  defp ev(props) do
    body =
      props
      |> String.trim()
      |> String.split("\n")
      |> Enum.map_join(&(&1 <> "\r\n"))

    "BEGIN:VEVENT\r\n" <> body <> "END:VEVENT\r\n"
  end

  defp one(props) do
    feed = feed!(cal(ev(props)))
    assert feed.malformed == 0
    assert [%Event{} = event] = feed.events
    event
  end

  defp series(feed_or_text)

  defp series(%Feed{} = feed) do
    {overrides, [master]} = Enum.split_with(feed.events, &(&1.recurrence_id != nil))
    {master, overrides}
  end

  defp series(text) when is_binary(text), do: series(feed!(text))

  defp series_for(%Feed{} = feed, uid) do
    {overrides, masters} = Enum.split_with(feed.events, &(&1.recurrence_id != nil))
    master = Enum.find(masters, &(&1.uid == uid))
    assert master, "no master with uid #{uid}"
    {master, Enum.filter(overrides, &(&1.uid == uid))}
  end

  defp expand!(text, from, to, zone \\ "Europe/Zurich") do
    {master, overrides} = series(text)
    Ics.expand(master, overrides, from, to, zone)
  end

  defp expand_props(props, from, to, zone \\ "Europe/Zurich") do
    expand!(cal(ev(props)), from, to, zone)
  end

  defp starts(occs), do: Enum.map(occs, & &1.start)
  defp spans(occs), do: Enum.map(occs, &{&1.start, Map.fetch!(&1, :end)})
  defp date_spans(occs), do: Enum.map(occs, &{&1.start_date, &1.end_date})

  defp feed_with(events_count, total, malformed) do
    %Feed{
      events: List.duplicate(%Event{uid: "u"}, events_count),
      total_vevents: total,
      malformed: malformed
    }
  end

  # ---------------------------------------------------------------- tokenizer

  describe "tokenizer — unfolding" do
    test "CRLF + leading-space continuation joins with the one octet removed" do
      raw =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u1\r\n" <>
          "DTSTART:20260706T090000Z\r\nSUMMARY:Te\r\n am\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      assert [%Event{summary: "Team"}] = feed!(raw).events
    end

    test "tab continuation is accepted" do
      raw =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u1\r\n" <>
          "DTSTART:20260706T090000Z\r\nSUMMARY:Te\r\n\tam\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      assert [%Event{summary: "Team"}] = feed!(raw).events
    end

    test "LF-only input unfolds the same way" do
      raw =
        "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:u1\n" <>
          "DTSTART:20260706T090000Z\nSUMMARY:Te\n am\nEND:VEVENT\nEND:VCALENDAR\n"

      assert [%Event{summary: "Team"}] = feed!(raw).events
    end

    test "a line folded across three physical lines reassembles" do
      raw =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u1\r\n" <>
          "DTSTART:20260706T090000Z\r\nSUMMARY:T\r\n e\r\n am\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      assert [%Event{summary: "Team"}] = feed!(raw).events
    end
  end

  describe "tokenizer — escaping and parameters" do
    test "TEXT unescaping handles \\n, \\N, \\,, \\; and \\\\ in text values only" do
      event =
        one(~S"""
        UID:esc@example.com
        DTSTART:20260706T090000Z
        SUMMARY:One\nTwo\, three\; four\\five
        DESCRIPTION:A\NB
        LOCATION:Rue du Marché 12\, Genève
        """)

      assert event.summary == "One\nTwo, three; four\\five"
      assert event.description == "A\nB"
      assert event.location == "Rue du Marché 12, Genève"
    end

    test "quoted parameter values may contain colons and semicolons" do
      event =
        one("""
        UID:q@example.com
        DTSTART;TZID="Europe/Zurich":20260706T140000
        SUMMARY;X-LABEL="semi;colon:here":Hello
        """)

      assert event.dtstart == {:zoned, ~N[2026-07-06 14:00:00], "Europe/Zurich"}
      assert event.summary == "Hello"
    end

    test "unknown properties and parameters are skipped silently" do
      event =
        one("""
        UID:x@example.com
        DTSTART:20260706T090000Z
        X-CUSTOM-THING;X-P=1:whatever
        SUMMARY;LANGUAGE=de:Ops Review
        """)

      assert event.summary == "Ops Review"
    end
  end

  describe "tokenizer — value types" do
    test "DATE, floating, UTC and TZID DATE-TIME forms produce tagged values" do
      assert one("UID:a\nDTSTART;VALUE=DATE:20260721").dtstart == {:date, ~D[2026-07-21]}
      assert one("UID:b\nDTSTART:20260706T093000").dtstart == {:floating, ~N[2026-07-06 09:30:00]}
      assert one("UID:c\nDTSTART:20260706T093000Z").dtstart == {:utc, ~U[2026-07-06 09:30:00Z]}

      assert one("UID:d\nDTSTART;TZID=Europe/Zurich:20260706T093000").dtstart ==
               {:zoned, ~N[2026-07-06 09:30:00], "Europe/Zurich"}
    end

    test "a bare 8-digit value is a DATE even without VALUE=DATE" do
      event = one("UID:a\nDTSTART:20260721")
      assert event.dtstart == {:date, ~D[2026-07-21]}
      assert event.all_day == true
    end

    test "all_day is set from a DATE-typed DTSTART" do
      assert one("UID:a\nDTSTART;VALUE=DATE:20260721").all_day == true
      assert one("UID:b\nDTSTART:20260706T093000Z").all_day == false
    end

    test "DURATION parses to seconds" do
      assert one("UID:a\nDTSTART:20260706T090000Z\nDURATION:PT1H30M").duration == 5400
      assert one("UID:b\nDTSTART:20260706T090000Z\nDURATION:P1DT2H").duration == 93_600
      assert one("UID:c\nDTSTART;VALUE=DATE:20260706\nDURATION:P1W").duration == 604_800
    end

    test "RRULE keeps its raw string for views" do
      event = one("UID:a\nDTSTART:20260706T090000Z\nRRULE:FREQ=WEEKLY;BYDAY=MO")
      assert event.rrule.raw == "FREQ=WEEKLY;BYDAY=MO"
    end

    test "EXDATE lists accumulate across properties and comma lists" do
      event =
        one("""
        UID:ex@example.com
        DTSTART;TZID=Europe/Zurich:20260706T090000
        RRULE:FREQ=DAILY;COUNT=5
        EXDATE;TZID=Europe/Zurich:20260707T090000,20260708T090000
        EXDATE;TZID=Europe/Zurich:20260709T090000
        """)

      assert length(event.exdate) == 3
    end

    test "metadata properties land on the struct" do
      event =
        one("""
        UID:meta@example.com
        DTSTART:20260706T090000Z
        STATUS:confirmed
        TRANSP:OPAQUE
        SEQUENCE:7
        LAST-MODIFIED:20260701T080000Z
        """)

      assert event.status == "CONFIRMED"
      assert event.transp == "OPAQUE"
      assert event.sequence == 7
      assert event.last_modified == {:utc, ~U[2026-07-01 08:00:00Z]}
    end
  end

  # ---------------------------------------------------------------- components

  describe "component reading" do
    test "VALARM sub-components are read past without touching VEVENT properties" do
      event =
        one("""
        UID:alarm@example.com
        DTSTART:20260706T090000Z
        SUMMARY:Master summary
        BEGIN:VALARM
        ACTION:DISPLAY
        DESCRIPTION:Reminder
        TRIGGER:-PT15M
        UID:alarm-sub-uid
        END:VALARM
        """)

      assert event.uid == "alarm@example.com"
      assert event.summary == "Master summary"
      assert event.description == nil
    end

    test "VTIMEZONE properties never leak into events" do
      feed = feed!(fixture("google-weekly.ics"))
      assert feed.total_vevents == 2
      refute Enum.any?(feed.events, &(&1.rrule && &1.rrule.raw =~ "BYMONTH=3"))
    end

    test "an HTML error page is {:error, :not_ics}" do
      assert Ics.parse(fixture("error-page.html")) == {:error, :not_ics}
    end

    test "arbitrary text is {:error, :not_ics}" do
      assert Ics.parse("hello world\r\nnothing calendar-shaped here") == {:error, :not_ics}
    end

    test "an empty VCALENDAR parses to an empty feed" do
      assert {:ok, %Feed{events: [], total_vevents: 0, malformed: 0}} = Ics.parse(cal(""))
    end
  end

  describe "malformed VEVENT accounting" do
    test "a malformed VEVENT is skipped, counted, and noticed" do
      text =
        cal(
          ev("UID:ok@example.com\nDTSTART:20260706T090000Z") <>
            ev("UID:bad@example.com\nDTSTART:banana") <>
            ev("SUMMARY:no uid\nDTSTART:20260707T090000Z")
        )

      feed = feed!(text)
      assert feed.total_vevents == 3
      assert feed.malformed == 2
      assert [%Event{uid: "ok@example.com"}] = feed.events
      assert length(feed.notices) == 2
      assert Enum.all?(feed.notices, &is_binary/1)
    end

    test "a VEVENT left open at EOF counts malformed" do
      raw = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u\r\nDTSTART:20260706T090000Z\r\n"
      feed = feed!(raw)
      assert feed.total_vevents == 1
      assert feed.malformed == 1
      assert feed.events == []
    end
  end

  # ---------------------------------------------------------------- resolve/2

  describe "resolve/2" do
    test "passes through dates and UTC instants" do
      assert Ics.resolve({:date, ~D[2026-07-21]}, "Europe/Zurich") == {:date, ~D[2026-07-21]}

      assert Ics.resolve({:utc, ~U[2026-07-21 07:00:00Z]}, "Europe/Zurich") ==
               {:ok, ~U[2026-07-21 07:00:00Z]}
    end

    test "floating resolves against the host zone" do
      assert Ics.resolve({:floating, ~N[2026-07-21 09:00:00]}, "Europe/Zurich") ==
               {:ok, ~U[2026-07-21 07:00:00Z]}
    end

    test "zoned resolves via IANA tzdata" do
      assert Ics.resolve({:zoned, ~N[2026-07-06 14:00:00], "Europe/Zurich"}, "Etc/UTC") ==
               {:ok, ~U[2026-07-06 12:00:00Z]}
    end

    test "ambiguous local time takes the EARLIER UTC instant" do
      assert Ics.resolve({:zoned, ~N[2026-10-25 02:30:00], "Europe/Zurich"}, "Etc/UTC") ==
               {:ok, ~U[2026-10-25 00:30:00Z]}
    end

    test "nonexistent local time takes the first instant AFTER the gap" do
      assert Ics.resolve({:zoned, ~N[2026-03-29 02:30:00], "Europe/Zurich"}, "Etc/UTC") ==
               {:ok, ~U[2026-03-29 01:00:00Z]}
    end

    test "the DST rules apply to floating times against the host zone too" do
      assert Ics.resolve({:floating, ~N[2026-10-25 02:30:00]}, "Europe/Zurich") ==
               {:ok, ~U[2026-10-25 00:30:00Z]}

      assert Ics.resolve({:floating, ~N[2026-03-29 02:30:00]}, "Europe/Zurich") ==
               {:ok, ~U[2026-03-29 01:00:00Z]}
    end

    test "Windows TZIDs resolve through the alias table" do
      assert Ics.resolve({:zoned, ~N[2026-07-13 09:00:00], "W. Europe Standard Time"}, "Etc/UTC") ==
               {:ok, ~U[2026-07-13 07:00:00Z]}

      assert Ics.resolve({:zoned, ~N[2026-07-13 09:00:00], "Romance Standard Time"}, "Etc/UTC") ==
               {:ok, ~U[2026-07-13 07:00:00Z]}
    end

    test "an unknown TZID is refused, never guessed" do
      assert Ics.resolve({:zoned, ~N[2026-07-13 09:00:00], "Klingon Standard Time"}, "Etc/UTC") ==
               {:error, :unknown_tzid}
    end
  end

  # ---------------------------------------------------------------- expansion

  describe "expansion — basics" do
    test "a single event without RRULE yields one occurrence" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:s@example.com
                 DTSTART;TZID=Europe/Zurich:20260706T090000
                 DTEND;TZID=Europe/Zurich:20260706T100000
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )

      assert spans(occs) == [{~U[2026-07-06 07:00:00Z], ~U[2026-07-06 08:00:00Z]}]
      assert [%{all_day: false}] = occs
    end

    test "a timed event without DTEND or DURATION is zero-length" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:z@example.com
                 DTSTART;TZID=Europe/Zurich:20260706T090000
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )

      assert spans(occs) == [{~U[2026-07-06 07:00:00Z], ~U[2026-07-06 07:00:00Z]}]
    end

    test "DURATION supplies the end when DTEND is absent" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:d@example.com
                 DTSTART:20260706T090000Z
                 DURATION:PT1H30M
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31],
                 "Etc/UTC"
               )

      assert spans(occs) == [{~U[2026-07-06 09:00:00Z], ~U[2026-07-06 10:30:00Z]}]
    end

    test "FREQ=DAILY with COUNT includes DTSTART in the count" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260706T090000
                 DTEND;TZID=Europe/Zurich:20260706T093000
                 RRULE:FREQ=DAILY;COUNT=3
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )

      assert starts(occs) == [
               ~U[2026-07-06 07:00:00Z],
               ~U[2026-07-07 07:00:00Z],
               ~U[2026-07-08 07:00:00Z]
             ]
    end

    test "INTERVAL stretches the period" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260706T090000
                 RRULE:FREQ=DAILY;INTERVAL=3;COUNT=3
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )

      assert starts(occs) == [
               ~U[2026-07-06 07:00:00Z],
               ~U[2026-07-09 07:00:00Z],
               ~U[2026-07-12 07:00:00Z]
             ]
    end

    test "UNTIL in UTC form is inclusive and compared as an instant" do
      props = fn until ->
        """
        UID:r@example.com
        DTSTART;TZID=Europe/Zurich:20260706T090000
        RRULE:FREQ=DAILY;UNTIL=#{until}
        """
      end

      assert {:ok, occs, []} =
               expand_props(props.("20260708T070000Z"), ~D[2026-07-01], ~D[2026-07-31])

      assert length(occs) == 3

      assert {:ok, occs, []} =
               expand_props(props.("20260708T065959Z"), ~D[2026-07-01], ~D[2026-07-31])

      assert length(occs) == 2
    end

    test "UNTIL in DATE form is inclusive and compared as a date" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260706T090000
                 RRULE:FREQ=DAILY;UNTIL=20260708
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )

      assert starts(occs) == [
               ~U[2026-07-06 07:00:00Z],
               ~U[2026-07-07 07:00:00Z],
               ~U[2026-07-08 07:00:00Z]
             ]
    end
  end

  describe "expansion — BYxxx" do
    test "WEEKLY with BYDAY expands within each week" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260706T090000
                 RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=5
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )

      assert starts(occs) == [
               ~U[2026-07-06 07:00:00Z],
               ~U[2026-07-08 07:00:00Z],
               ~U[2026-07-10 07:00:00Z],
               ~U[2026-07-13 07:00:00Z],
               ~U[2026-07-15 07:00:00Z]
             ]
    end

    test "WKST changes which week is on for WEEKLY with INTERVAL=2 (RFC 5545 example)" do
      props = fn wkst ->
        """
        UID:r@example.com
        DTSTART:19970805T090000
        RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU#{wkst}
        """
      end

      assert {:ok, occs, []} =
               expand_props(props.(";WKST=MO"), ~D[1997-08-01], ~D[1997-09-30], "Etc/UTC")

      assert starts(occs) == [
               ~U[1997-08-05 09:00:00Z],
               ~U[1997-08-10 09:00:00Z],
               ~U[1997-08-19 09:00:00Z],
               ~U[1997-08-24 09:00:00Z]
             ]

      assert {:ok, occs, []} =
               expand_props(props.(";WKST=SU"), ~D[1997-08-01], ~D[1997-09-30], "Etc/UTC")

      assert starts(occs) == [
               ~U[1997-08-05 09:00:00Z],
               ~U[1997-08-17 09:00:00Z],
               ~U[1997-08-19 09:00:00Z],
               ~U[1997-08-31 09:00:00Z]
             ]

      # default WKST is MO
      assert {:ok, occs, []} = expand_props(props.(""), ~D[1997-08-01], ~D[1997-09-30], "Etc/UTC")

      assert starts(occs) == [
               ~U[1997-08-05 09:00:00Z],
               ~U[1997-08-10 09:00:00Z],
               ~U[1997-08-19 09:00:00Z],
               ~U[1997-08-24 09:00:00Z]
             ]
    end

    test "MONTHLY BYDAY with a positive ordinal (second Monday)" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260713T090000
                 RRULE:FREQ=MONTHLY;BYDAY=2MO;COUNT=3
                 """,
                 ~D[2026-07-01],
                 ~D[2026-09-30]
               )

      assert starts(occs) == [
               ~U[2026-07-13 07:00:00Z],
               ~U[2026-08-10 07:00:00Z],
               ~U[2026-09-14 07:00:00Z]
             ]
    end

    test "MONTHLY BYDAY with a negative ordinal (last Friday)" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260731T090000
                 RRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=3
                 """,
                 ~D[2026-07-01],
                 ~D[2026-09-30]
               )

      assert starts(occs) == [
               ~U[2026-07-31 07:00:00Z],
               ~U[2026-08-28 07:00:00Z],
               ~U[2026-09-25 07:00:00Z]
             ]
    end

    test "MONTHLY BYMONTHDAY, positive and negative" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260715T090000
                 RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3
                 """,
                 ~D[2026-07-01],
                 ~D[2026-09-30]
               )

      assert starts(occs) == [
               ~U[2026-07-15 07:00:00Z],
               ~U[2026-08-15 07:00:00Z],
               ~U[2026-09-15 07:00:00Z]
             ]

      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260731T090000
                 RRULE:FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=3
                 """,
                 ~D[2026-07-01],
                 ~D[2026-09-30]
               )

      assert starts(occs) == [
               ~U[2026-07-31 07:00:00Z],
               ~U[2026-08-31 07:00:00Z],
               ~U[2026-09-30 07:00:00Z]
             ]
    end

    test "MONTHLY on the 31st skips short months" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260131T090000
                 RRULE:FREQ=MONTHLY;COUNT=3
                 """,
                 ~D[2026-01-01],
                 ~D[2026-12-31]
               )

      # Feb and Apr have no 31st; note the DST offset change inside the series.
      assert starts(occs) == [
               ~U[2026-01-31 08:00:00Z],
               ~U[2026-03-31 07:00:00Z],
               ~U[2026-05-31 07:00:00Z]
             ]
    end

    test "BYSETPOS selects from the period's candidate set (last weekday of month)" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260731T090000
                 RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3
                 """,
                 ~D[2026-07-01],
                 ~D[2026-12-31]
               )

      assert starts(occs) == [
               ~U[2026-07-31 07:00:00Z],
               ~U[2026-08-31 07:00:00Z],
               ~U[2026-09-30 07:00:00Z]
             ]
    end

    test "DAILY BYDAY acts as a weekday filter" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260710T090000
                 RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;COUNT=4
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )

      assert starts(occs) == [
               ~U[2026-07-10 07:00:00Z],
               ~U[2026-07-13 07:00:00Z],
               ~U[2026-07-14 07:00:00Z],
               ~U[2026-07-15 07:00:00Z]
             ]
    end

    test "YEARLY without BYxxx repeats the start date" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260214T090000
                 RRULE:FREQ=YEARLY;COUNT=3
                 """,
                 ~D[2026-01-01],
                 ~D[2028-12-31]
               )

      assert starts(occs) == [
               ~U[2026-02-14 08:00:00Z],
               ~U[2027-02-14 08:00:00Z],
               ~U[2028-02-14 08:00:00Z]
             ]
    end

    test "YEARLY BYMONTH expands to each listed month" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260701T090000
                 RRULE:FREQ=YEARLY;BYMONTH=1,7;COUNT=4
                 """,
                 ~D[2026-01-01],
                 ~D[2028-12-31]
               )

      assert starts(occs) == [
               ~U[2026-07-01 07:00:00Z],
               ~U[2027-01-01 08:00:00Z],
               ~U[2027-07-01 07:00:00Z],
               ~U[2028-01-01 08:00:00Z]
             ]
    end

    test "YEARLY BYMONTH + ordinal BYDAY (fourth Thursday of November)" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20261126T090000
                 RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH;COUNT=2
                 """,
                 ~D[2026-01-01],
                 ~D[2028-12-31]
               )

      assert starts(occs) == [
               ~U[2026-11-26 08:00:00Z],
               ~U[2027-11-25 08:00:00Z]
             ]
    end
  end

  describe "expansion — EXDATE and RDATE" do
    test "EXDATE removes after COUNT is applied" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260706T090000
                 RRULE:FREQ=DAILY;COUNT=3
                 EXDATE;TZID=Europe/Zurich:20260707T090000
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )

      assert starts(occs) == [~U[2026-07-06 07:00:00Z], ~U[2026-07-08 07:00:00Z]]
    end

    test "RDATE adds an occurrence with the master's duration" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260706T090000
                 DTEND;TZID=Europe/Zurich:20260706T093000
                 RDATE;TZID=Europe/Zurich:20260710T140000
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )

      assert spans(occs) == [
               {~U[2026-07-06 07:00:00Z], ~U[2026-07-06 07:30:00Z]},
               {~U[2026-07-10 12:00:00Z], ~U[2026-07-10 12:30:00Z]}
             ]
    end

    test "an RDATE equal to an existing occurrence does not duplicate it" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260706T090000
                 RDATE;TZID=Europe/Zurich:20260706T090000
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )

      assert length(occs) == 1
    end
  end

  describe "expansion — overrides" do
    test "an override replaces its occurrence at the canonical instant" do
      text =
        cal(
          ev("""
          UID:o1@example.com
          DTSTART;TZID=Europe/Zurich:20260706T090000
          DTEND;TZID=Europe/Zurich:20260706T093000
          RRULE:FREQ=DAILY;COUNT=3
          SUMMARY:Original
          """) <>
            ev("""
            UID:o1@example.com
            RECURRENCE-ID;TZID=Europe/Zurich:20260707T090000
            DTSTART;TZID=Europe/Zurich:20260707T110000
            DTEND;TZID=Europe/Zurich:20260707T113000
            SUMMARY:Moved
            """)
        )

      assert {:ok, occs, []} = expand!(text, ~D[2026-07-01], ~D[2026-07-31])

      assert spans(occs) == [
               {~U[2026-07-06 07:00:00Z], ~U[2026-07-06 07:30:00Z]},
               {~U[2026-07-07 09:00:00Z], ~U[2026-07-07 09:30:00Z]},
               {~U[2026-07-08 07:00:00Z], ~U[2026-07-08 07:30:00Z]}
             ]

      moved = Enum.find(occs, &(&1.start == ~U[2026-07-07 09:00:00Z]))
      assert moved.event.summary == "Moved"
    end

    test "a UTC-form RECURRENCE-ID matches a TZID-form occurrence (canonical instants)" do
      text =
        cal(
          ev("""
          UID:o2@example.com
          DTSTART;TZID=Europe/Zurich:20260706T090000
          RRULE:FREQ=DAILY;COUNT=2
          """) <>
            ev("""
            UID:o2@example.com
            RECURRENCE-ID:20260707T070000Z
            DTSTART;TZID=Europe/Zurich:20260707T120000
            """)
        )

      assert {:ok, occs, []} = expand!(text, ~D[2026-07-01], ~D[2026-07-31])
      assert starts(occs) == [~U[2026-07-06 07:00:00Z], ~U[2026-07-07 10:00:00Z]]
    end

    test "a CANCELLED override removes its occurrence" do
      text =
        cal(
          ev("""
          UID:o3@example.com
          DTSTART;TZID=Europe/Zurich:20260706T090000
          RRULE:FREQ=DAILY;COUNT=3
          """) <>
            ev("""
            UID:o3@example.com
            RECURRENCE-ID;TZID=Europe/Zurich:20260707T090000
            DTSTART;TZID=Europe/Zurich:20260707T090000
            STATUS:CANCELLED
            """)
        )

      assert {:ok, occs, []} = expand!(text, ~D[2026-07-01], ~D[2026-07-31])
      assert starts(occs) == [~U[2026-07-06 07:00:00Z], ~U[2026-07-08 07:00:00Z]]
    end

    test "a CANCELLED master yields no occurrences at all" do
      assert {:ok, [], []} =
               expand_props(
                 """
                 UID:c@example.com
                 DTSTART;TZID=Europe/Zurich:20260706T090000
                 RRULE:FREQ=DAILY;COUNT=5
                 STATUS:CANCELLED
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )
    end

    test "an unmatched override becomes a standalone occurrence with a notice" do
      text =
        cal(
          ev("""
          UID:o4@example.com
          DTSTART;TZID=Europe/Zurich:20260706T090000
          RRULE:FREQ=DAILY;COUNT=2
          """) <>
            ev("""
            UID:o4@example.com
            RECURRENCE-ID;TZID=Europe/Zurich:20260720T090000
            DTSTART;TZID=Europe/Zurich:20260720T100000
            DTEND;TZID=Europe/Zurich:20260720T103000
            """)
        )

      assert {:ok, occs, [notice]} = expand!(text, ~D[2026-07-01], ~D[2026-07-31])
      assert notice =~ "override"

      assert starts(occs) == [
               ~U[2026-07-06 07:00:00Z],
               ~U[2026-07-07 07:00:00Z],
               ~U[2026-07-20 08:00:00Z]
             ]
    end

    test "a floating RECURRENCE-ID only matches floating occurrences" do
      # Master is floating (host Europe/Zurich → 07:00Z); the override's
      # RECURRENCE-ID names the same instant but in zoned form — no match.
      text =
        cal(
          ev("""
          UID:o5@example.com
          DTSTART:20260706T090000
          RRULE:FREQ=DAILY;COUNT=2
          """) <>
            ev("""
            UID:o5@example.com
            RECURRENCE-ID;TZID=Europe/Zurich:20260707T090000
            DTSTART;TZID=Europe/Zurich:20260707T100000
            """)
        )

      assert {:ok, occs, [notice]} = expand!(text, ~D[2026-07-01], ~D[2026-07-31])
      assert notice =~ "override"

      assert starts(occs) == [
               ~U[2026-07-06 07:00:00Z],
               ~U[2026-07-07 07:00:00Z],
               ~U[2026-07-07 08:00:00Z]
             ]
    end

    test "an all-day override matches on the plain date" do
      text =
        cal(
          ev("""
          UID:o6@example.com
          DTSTART;VALUE=DATE:20260706
          RRULE:FREQ=WEEKLY;COUNT=3
          """) <>
            ev("""
            UID:o6@example.com
            RECURRENCE-ID;VALUE=DATE:20260713
            DTSTART;VALUE=DATE:20260714
            """)
        )

      assert {:ok, occs, []} = expand!(text, ~D[2026-07-01], ~D[2026-07-31])

      assert date_spans(occs) == [
               {~D[2026-07-06], ~D[2026-07-07]},
               {~D[2026-07-14], ~D[2026-07-15]},
               {~D[2026-07-20], ~D[2026-07-21]}
             ]
    end
  end

  describe "expansion — unsupported recurrence emits NOTHING" do
    test "BYWEEKNO is unsupported with the pinned reason" do
      assert expand_props(
               """
               UID:r@example.com
               DTSTART;TZID=Europe/Zurich:20260511T090000
               RRULE:FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO
               """,
               ~D[2026-01-01],
               ~D[2026-12-31]
             ) == {:unsupported, "rrule part BYWEEKNO"}
    end

    test "BYYEARDAY and BYHOUR are unsupported" do
      for part <- ["BYYEARDAY=100", "BYHOUR=9"] do
        [name, _] = String.split(part, "=")

        assert expand_props(
                 """
                 UID:r@example.com
                 DTSTART;TZID=Europe/Zurich:20260706T090000
                 RRULE:FREQ=YEARLY;#{part}
                 """,
                 ~D[2026-01-01],
                 ~D[2026-12-31]
               ) == {:unsupported, "rrule part #{name}"}
      end
    end

    test "sub-daily FREQ, missing FREQ, and broken values are unsupported" do
      for rrule <- [
            "FREQ=HOURLY;COUNT=3",
            "COUNT=3",
            "FREQ=DAILY;INTERVAL=0",
            "FREQ=DAILY;COUNT=abc"
          ] do
        assert {:unsupported, reason} =
                 expand_props(
                   """
                   UID:r@example.com
                   DTSTART;TZID=Europe/Zurich:20260706T090000
                   RRULE:#{rrule}
                   """,
                   ~D[2026-07-01],
                   ~D[2026-07-31]
                 )

        assert is_binary(reason)
      end
    end

    test "ordinal BYDAY and BYMONTHDAY are unsupported with WEEKLY" do
      for rrule <- ["FREQ=WEEKLY;BYDAY=2MO", "FREQ=WEEKLY;BYMONTHDAY=15"] do
        assert {:unsupported, reason} =
                 expand_props(
                   """
                   UID:r@example.com
                   DTSTART;TZID=Europe/Zurich:20260706T090000
                   RRULE:#{rrule}
                   """,
                   ~D[2026-07-01],
                   ~D[2026-07-31]
                 )

        assert is_binary(reason)
      end
    end

    test "an unknown TZID makes the whole series unsupported — even without RRULE" do
      for props <- [
            "UID:r@example.com\nDTSTART;TZID=Mars/Olympus:20260706T090000",
            "UID:r@example.com\nDTSTART;TZID=Mars/Olympus:20260706T090000\nRRULE:FREQ=DAILY;COUNT=2"
          ] do
        assert expand_props(props, ~D[2026-07-01], ~D[2026-07-31]) ==
                 {:unsupported, "unknown TZID Mars/Olympus"}
      end
    end

    test "expansion halts at the iteration cap" do
      assert expand_props(
               """
               UID:cap@example.com
               DTSTART:19000101T090000Z
               RRULE:FREQ=DAILY
               """,
               ~D[2200-01-01],
               ~D[2200-01-02],
               "Etc/UTC"
             ) == {:unsupported, "iteration cap"}
    end

    test "THISANDFUTURE override marks the whole series unsupported" do
      feed = feed!(fixture("thisandfuture.ics"))
      {master, [override]} = series(feed)
      assert override.thisandfuture == true

      assert Ics.expand(master, [override], ~D[2026-07-01], ~D[2026-08-31], "Europe/Zurich") ==
               {:unsupported, "THISANDFUTURE override"}
    end
  end

  describe "expansion — DST boundaries (Europe/Zurich 2026)" do
    test "spring-forward: the nonexistent 02:30 resolves to the first instant after the gap" do
      feed = feed!(fixture("dst-boundary.ics"))
      {master, overrides} = series_for(feed, "dst-spring@example.com")

      assert {:ok, occs, []} =
               Ics.expand(master, overrides, ~D[2026-03-01], ~D[2026-04-30], "Europe/Zurich")

      assert spans(occs) == [
               {~U[2026-03-15 01:30:00Z], ~U[2026-03-15 02:30:00Z]},
               {~U[2026-03-22 01:30:00Z], ~U[2026-03-22 02:30:00Z]},
               {~U[2026-03-29 01:00:00Z], ~U[2026-03-29 02:00:00Z]},
               {~U[2026-04-05 00:30:00Z], ~U[2026-04-05 01:30:00Z]}
             ]
    end

    test "fall-back: ambiguous 02:30 takes the earlier instant, and the EXDATE in the ambiguous hour removes exactly that occurrence" do
      feed = feed!(fixture("dst-boundary.ics"))
      {master, overrides} = series_for(feed, "dst-fall@example.com")

      assert {:ok, occs, []} =
               Ics.expand(master, overrides, ~D[2026-10-01], ~D[2026-11-30], "Europe/Zurich")

      assert spans(occs) == [
               {~U[2026-10-11 00:30:00Z], ~U[2026-10-11 01:30:00Z]},
               {~U[2026-10-18 00:30:00Z], ~U[2026-10-18 01:30:00Z]},
               {~U[2026-11-01 01:30:00Z], ~U[2026-11-01 02:30:00Z]}
             ]
    end
  end

  describe "expansion — window semantics" do
    test "an event straddling the window start is included (overlap, not start-filter)" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:w@example.com
                 DTSTART;TZID=Europe/Zurich:20260705T230000
                 DTEND;TZID=Europe/Zurich:20260706T010000
                 """,
                 ~D[2026-07-06],
                 ~D[2026-07-06]
               )

      assert spans(occs) == [{~U[2026-07-05 21:00:00Z], ~U[2026-07-05 23:00:00Z]}]
    end

    test "an event ending exactly at the window start is excluded (half-open)" do
      assert {:ok, [], []} =
               expand_props(
                 """
                 UID:w@example.com
                 DTSTART;TZID=Europe/Zurich:20260705T230000
                 DTEND;TZID=Europe/Zurich:20260706T000000
                 """,
                 ~D[2026-07-06],
                 ~D[2026-07-06]
               )
    end

    test "an event starting exactly at the window end is excluded (half-open)" do
      assert {:ok, [], []} =
               expand_props(
                 """
                 UID:w@example.com
                 DTSTART;TZID=Europe/Zurich:20260707T000000
                 DTEND;TZID=Europe/Zurich:20260707T010000
                 """,
                 ~D[2026-07-06],
                 ~D[2026-07-06]
               )
    end

    test "a zero-length event exactly at the window start is included" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:w@example.com
                 DTSTART;TZID=Europe/Zurich:20260706T000000
                 """,
                 ~D[2026-07-06],
                 ~D[2026-07-06]
               )

      assert spans(occs) == [{~U[2026-07-05 22:00:00Z], ~U[2026-07-05 22:00:00Z]}]
    end
  end

  describe "expansion — all-day" do
    test "a multi-day all-day event keeps its exclusive DATE end" do
      feed = feed!(fixture("icloud-allday.ics"))
      {master, overrides} = series(feed)

      assert {:ok, occs, []} =
               Ics.expand(master, overrides, ~D[2026-07-01], ~D[2026-08-31], "Europe/Zurich")

      assert [%{all_day: true}] = occs
      assert date_spans(occs) == [{~D[2026-07-21], ~D[2026-07-24]}]
    end

    test "an all-day event without DTEND lasts one day" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:a@example.com
                 DTSTART;VALUE=DATE:20260706
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )

      assert date_spans(occs) == [{~D[2026-07-06], ~D[2026-07-07]}]
    end

    test "all-day recurrence with a DATE-typed EXDATE" do
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:a@example.com
                 DTSTART;VALUE=DATE:20260706
                 RRULE:FREQ=WEEKLY;COUNT=3
                 EXDATE;VALUE=DATE:20260713
                 """,
                 ~D[2026-07-01],
                 ~D[2026-07-31]
               )

      assert date_spans(occs) == [
               {~D[2026-07-06], ~D[2026-07-07]},
               {~D[2026-07-20], ~D[2026-07-21]}
             ]
    end

    test "all-day occurrences overlap the window by date range" do
      # Jul 4–6 (end exclusive) overlaps a window starting Jul 5.
      assert {:ok, occs, []} =
               expand_props(
                 """
                 UID:a@example.com
                 DTSTART;VALUE=DATE:20260704
                 DTEND;VALUE=DATE:20260706
                 """,
                 ~D[2026-07-05],
                 ~D[2026-07-31]
               )

      assert date_spans(occs) == [{~D[2026-07-04], ~D[2026-07-06]}]

      # …but an event ending (exclusively) on the window start day does not.
      assert {:ok, [], []} =
               expand_props(
                 """
                 UID:a@example.com
                 DTSTART;VALUE=DATE:20260703
                 DTEND;VALUE=DATE:20260705
                 """,
                 ~D[2026-07-05],
                 ~D[2026-07-31]
               )
    end
  end

  # ------------------------------------------------------- identity functions

  describe "canonical_recurrence_id/2" do
    test "masters canonicalize to the empty string" do
      assert Ics.canonical_recurrence_id(%Event{recurrence_id: nil}, "Europe/Zurich") == ""
    end

    test "timed RECURRENCE-IDs canonicalize to UTC ISO8601" do
      assert Ics.canonical_recurrence_id(
               %Event{recurrence_id: {:zoned, ~N[2026-07-08 09:00:00], "Europe/Zurich"}},
               "Europe/Zurich"
             ) == "2026-07-08T07:00:00Z"

      assert Ics.canonical_recurrence_id(
               %Event{recurrence_id: {:utc, ~U[2026-07-08 07:00:00Z]}},
               "Europe/Zurich"
             ) == "2026-07-08T07:00:00Z"

      assert Ics.canonical_recurrence_id(
               %Event{recurrence_id: {:floating, ~N[2026-07-08 09:00:00]}},
               "Europe/Zurich"
             ) == "2026-07-08T07:00:00Z"
    end

    test "all-day RECURRENCE-IDs canonicalize to the ISO date" do
      assert Ics.canonical_recurrence_id(
               %Event{recurrence_id: {:date, ~D[2026-07-21]}},
               "Europe/Zurich"
             ) == "2026-07-21"
    end
  end

  describe "view_id/3" do
    test "pins the exact hash construction" do
      assert Ics.view_id("work", "evt-1@example.com", "") == "ev-9c800f86f79d0cb4"

      assert Ics.view_id("work", "evt-1@example.com", "2026-07-08T07:00:00Z") ==
               "ev-025cf26a3be0bd9e"
    end

    test "master and overrides of one UID get distinct ids" do
      feed = feed!(fixture("overrides-multi.ics"))

      ids =
        feed.events
        |> Enum.map(fn event ->
          rid = Ics.canonical_recurrence_id(event, "Europe/Zurich")
          Ics.view_id("work", event.uid, rid)
        end)

      assert length(Enum.uniq(ids)) == 4
      assert Enum.all?(ids, &String.match?(&1, ~r/^ev-[0-9a-f]{16}$/))
    end
  end

  describe "acceptable?/2" do
    test "zero parseable events where the previous snapshot had events is rejected" do
      assert Ics.acceptable?(feed_with(0, 0, 0), true) == {:error, :zero_parseable}
    end

    test "zero events without previous evidence is fine (a legitimately empty feed)" do
      assert Ics.acceptable?(feed_with(0, 0, 0), false) == :ok
    end

    test "one malformed of seven is imperfect but acceptable" do
      assert Ics.acceptable?(feed_with(6, 7, 1), true) == :ok
    end

    test "three malformed of seven trips the corruption guard" do
      assert Ics.acceptable?(feed_with(4, 7, 3), true) == {:error, :too_many_malformed}
    end

    test "two malformed of two trips the corruption guard even without previous events" do
      assert Ics.acceptable?(feed_with(0, 2, 2), false) == {:error, :too_many_malformed}
    end

    test "a shrunken but fully parseable feed is acceptable" do
      assert Ics.acceptable?(feed_with(2, 2, 0), true) == :ok
    end
  end

  # ------------------------------------------------------------ WindowsZones

  describe "WindowsZones" do
    test "maps CLDR 001 Windows names to IANA zones" do
      assert WindowsZones.to_iana("W. Europe Standard Time") == {:ok, "Europe/Berlin"}
      assert WindowsZones.to_iana("Pacific Standard Time") == {:ok, "America/Los_Angeles"}
      assert WindowsZones.to_iana("GMT Standard Time") == {:ok, "Europe/London"}
      assert WindowsZones.to_iana("China Standard Time") == {:ok, "Asia/Shanghai"}
      assert WindowsZones.to_iana("AUS Eastern Standard Time") == {:ok, "Australia/Sydney"}
      assert WindowsZones.to_iana("India Standard Time") == {:ok, "Asia/Calcutta"}
      assert WindowsZones.to_iana("UTC") == {:ok, "Etc/UTC"}
    end

    test "unknown names are :error" do
      assert WindowsZones.to_iana("Klingon Standard Time") == :error
      assert WindowsZones.to_iana("") == :error
    end

    test "the table is the full CLDR 001 mapping, and every target resolves in tzdata" do
      table = WindowsZones.all()
      assert map_size(table) >= 130

      for {windows_name, iana} <- table do
        assert match?({:ok, _}, DateTime.now(iana)),
               "#{windows_name} maps to #{iana}, which tzdata cannot resolve"
      end
    end
  end

  # ---------------------------------------------------------------- fixtures

  describe "fixture round-trips" do
    test "google-weekly.ics: weekly TZID series with EXDATE and an override" do
      feed = feed!(fixture("google-weekly.ics"))
      assert feed.total_vevents == 2
      assert feed.malformed == 0

      {master, overrides} = series(feed)
      assert master.uid == "7d3k2n9a1b@google.com"
      assert master.summary == "Team sync"
      assert master.description == "Weekly team sync, bring updates and blockers."
      assert master.rrule.raw == "FREQ=WEEKLY;BYDAY=MO"
      assert [override] = overrides
      assert override.recurrence_id == {:zoned, ~N[2026-07-27 14:00:00], "Europe/Zurich"}

      assert {:ok, occs, []} =
               Ics.expand(master, overrides, ~D[2026-07-01], ~D[2026-08-02], "Europe/Zurich")

      assert spans(occs) == [
               {~U[2026-07-06 12:00:00Z], ~U[2026-07-06 13:00:00Z]},
               {~U[2026-07-13 12:00:00Z], ~U[2026-07-13 13:00:00Z]},
               {~U[2026-07-27 14:00:00Z], ~U[2026-07-27 15:00:00Z]}
             ]

      moved = Enum.find(occs, &(&1.start == ~U[2026-07-27 14:00:00Z]))
      assert moved.event.summary == "Team sync (moved)"
    end

    test "outlook-windows-tz.ics: Windows TZID chain plus BYSETPOS second-Monday rule" do
      feed = feed!(fixture("outlook-windows-tz.ics"))
      assert feed.malformed == 0

      {master, overrides} = series(feed)

      assert master.uid ==
               "040000008200E00074C5B7101A82E00800000000B0DE1D8E5A9BDC01000000000000000010000000D5A9E345F8C24D4B9F26AC5D3C7E8A91"

      assert master.summary == "Ops Review"
      assert master.description == "Monthly ops review\n"
      assert {:zoned, ~N[2026-07-13 09:00:00], "W. Europe Standard Time"} = master.dtstart

      assert {:ok, occs, []} =
               Ics.expand(master, overrides, ~D[2026-07-01], ~D[2026-09-30], "Europe/Zurich")

      assert spans(occs) == [
               {~U[2026-07-13 07:00:00Z], ~U[2026-07-13 08:00:00Z]},
               {~U[2026-08-10 07:00:00Z], ~U[2026-08-10 08:00:00Z]},
               {~U[2026-09-14 07:00:00Z], ~U[2026-09-14 08:00:00Z]}
             ]
    end

    test "infomaniak-basic.ics: LF-only UTC-time event" do
      feed = feed!(fixture("infomaniak-basic.ics"))
      {master, overrides} = series(feed)
      assert master.summary == "Dentist"
      assert master.location == "Rue du Marché 12, Genève"

      assert {:ok, occs, []} =
               Ics.expand(master, overrides, ~D[2026-07-01], ~D[2026-07-31], "Europe/Zurich")

      assert spans(occs) == [{~U[2026-07-22 07:30:00Z], ~U[2026-07-22 08:30:00Z]}]
    end

    test "overrides-multi.ics: two replacements and one cancelled override" do
      feed = feed!(fixture("overrides-multi.ics"))
      assert feed.total_vevents == 4
      assert feed.malformed == 0

      {master, overrides} = series(feed)
      assert length(overrides) == 3

      assert {:ok, occs, []} =
               Ics.expand(master, overrides, ~D[2026-07-01], ~D[2026-07-31], "Europe/Zurich")

      assert starts(occs) == [
               ~U[2026-07-06 07:00:00Z],
               ~U[2026-07-07 07:00:00Z],
               ~U[2026-07-08 09:00:00Z],
               ~U[2026-07-10 07:00:00Z],
               ~U[2026-07-11 07:00:00Z],
               ~U[2026-07-12 07:00:00Z],
               ~U[2026-07-13 07:00:00Z],
               ~U[2026-07-14 07:00:00Z],
               ~U[2026-07-15 07:00:00Z]
             ]

      moved = Enum.find(occs, &(&1.start == ~U[2026-07-08 09:00:00Z]))
      assert moved.event.summary == "Standup (moved)"

      guest = Enum.find(occs, &(&1.start == ~U[2026-07-10 07:00:00Z]))
      assert guest.event.summary == "Standup (guest: Priya)"
    end

    test "byweekno-unsupported.ics emits no occurrences, not even DTSTART" do
      feed = feed!(fixture("byweekno-unsupported.ics"))
      {master, overrides} = series(feed)

      assert Ics.expand(master, overrides, ~D[2026-01-01], ~D[2026-12-31], "Europe/Zurich") ==
               {:unsupported, "rrule part BYWEEKNO"}
    end

    test "malformed-mixed.ics: 3 of 7 malformed parses fail-soft but is not acceptable" do
      feed = feed!(fixture("malformed-mixed.ics"))
      assert feed.total_vevents == 7
      assert feed.malformed == 3
      assert length(feed.events) == 4
      assert length(feed.notices) == 3

      assert Enum.map(feed.events, & &1.uid) == [
               "good-1@example.com",
               "good-2@example.com",
               "good-3@example.com",
               "good-4@example.com"
             ]

      assert Ics.acceptable?(feed, true) == {:error, :too_many_malformed}
      assert Ics.acceptable?(feed, false) == {:error, :too_many_malformed}
    end
  end
end
