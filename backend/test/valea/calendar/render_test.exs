defmodule Valea.Calendar.RenderTest do
  use ExUnit.Case, async: true

  alias Valea.Calendar.Local
  alias Valea.Calendar.Local.Event
  alias Valea.Calendar.Render

  @mtime ~U[2026-07-18 09:30:00Z]

  defp timed_event(overrides \\ []) do
    struct!(
      %Event{
        name: "standup",
        path: "sources/calendar/valea/events/standup.md",
        title: "Standup",
        start: ~U[2026-07-21 07:30:00Z],
        end: ~U[2026-07-21 08:00:00Z],
        all_day: false,
        location: nil,
        status: "confirmed",
        description: "",
        mtime: @mtime
      },
      overrides
    )
  end

  defp all_day_event(overrides \\ []) do
    struct!(
      %Event{
        name: "retreat",
        path: "sources/calendar/valea/events/retreat.md",
        title: "Retreat",
        start: ~D[2026-07-21],
        end: ~D[2026-07-23],
        all_day: true,
        location: nil,
        status: "confirmed",
        description: "",
        mtime: @mtime
      },
      overrides
    )
  end

  # RFC 5545 unfold: a CRLF followed by a single space is a fold.
  defp unfold(ics), do: String.replace(ics, "\r\n ", "")

  defp physical_lines(ics), do: String.split(ics, "\r\n", trim: true)

  describe "calendar skeleton" do
    test "an empty feed is one well-formed VCALENDAR" do
      assert Render.feed([]) ==
               "BEGIN:VCALENDAR\r\n" <>
                 "VERSION:2.0\r\n" <>
                 "PRODID:-//Valea//Calendar//EN\r\n" <>
                 "CALSCALE:GREGORIAN\r\n" <>
                 "END:VCALENDAR\r\n"
    end

    test "every line ends with CRLF, no bare LF" do
      ics = Render.feed([timed_event()])
      refute ics =~ ~r/(?<!\r)\n/
      assert String.ends_with?(ics, "\r\n")
    end
  end

  describe "event composition" do
    test "a timed event renders UID, DTSTAMP/LAST-MODIFIED from mtime, UTC times, STATUS" do
      lines = Render.feed([timed_event()]) |> unfold() |> physical_lines()

      assert "UID:" <> uid = Enum.find(lines, &String.starts_with?(&1, "UID:"))
      assert uid == Local.uid("standup")

      assert "DTSTAMP:20260718T093000Z" in lines
      assert "LAST-MODIFIED:20260718T093000Z" in lines
      assert "SUMMARY:Standup" in lines
      assert "DTSTART:20260721T073000Z" in lines
      assert "DTEND:20260721T080000Z" in lines
      assert "STATUS:CONFIRMED" in lines
      refute Enum.any?(lines, &String.starts_with?(&1, "LOCATION"))
      refute Enum.any?(lines, &String.starts_with?(&1, "DESCRIPTION"))
    end

    test "DTSTAMP and LAST-MODIFIED both render the event's mtime (controlled via File.touch!)" do
      root =
        Path.join(
          System.tmp_dir!(),
          "valea-cal-render-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        )

      events = Path.join(root, "sources/calendar/valea/events")
      File.mkdir_p!(events)
      on_exit(fn -> File.rm_rf!(root) end)

      path = Path.join(events, "touched.md")
      File.write!(path, "---\ntitle: \"T\"\nstart: 2026-07-21T09:30:00+02:00\n---\n")
      File.touch!(path, DateTime.to_unix(~U[2026-07-18 06:15:42Z]))

      assert %{valid: [event], invalid: []} = Local.list(root)
      lines = Render.feed([event]) |> unfold() |> physical_lines()

      assert "DTSTAMP:20260718T061542Z" in lines
      assert "LAST-MODIFIED:20260718T061542Z" in lines
      # Fixed-offset start rendered in the UTC "Z" form.
      assert "DTSTART:20260721T073000Z" in lines
    end

    test "a fixed-offset start/end is normalized to the UTC Z form" do
      wall = ~N[2026-07-21 09:30:00]

      fixed = %DateTime{
        year: wall.year,
        month: wall.month,
        day: wall.day,
        hour: wall.hour,
        minute: wall.minute,
        second: wall.second,
        microsecond: {0, 0},
        time_zone: "+02:00",
        zone_abbr: "+02:00",
        utc_offset: 7200,
        std_offset: 0
      }

      lines =
        Render.feed([
          timed_event(start: fixed, end: DateTime.add(~U[2026-07-21 07:30:00Z], 1800))
        ])
        |> unfold()
        |> physical_lines()

      assert "DTSTART:20260721T073000Z" in lines
      assert "DTEND:20260721T080000Z" in lines
    end

    test "an all-day event renders VALUE=DATE with the exclusive end" do
      lines = Render.feed([all_day_event()]) |> unfold() |> physical_lines()

      assert "DTSTART;VALUE=DATE:20260721" in lines
      assert "DTEND;VALUE=DATE:20260723" in lines
    end

    test "cancelled and tentative statuses render upcased" do
      lines =
        Render.feed([timed_event(status: "cancelled"), all_day_event(status: "tentative")])
        |> unfold()
        |> physical_lines()

      assert "STATUS:CANCELLED" in lines
      assert "STATUS:TENTATIVE" in lines
    end

    test "location and description render when present" do
      lines =
        Render.feed([timed_event(location: "Café Anton", description: "Agenda")])
        |> unfold()
        |> physical_lines()

      assert "LOCATION:Café Anton" in lines
      assert "DESCRIPTION:Agenda" in lines
    end
  end

  describe "escaping — agent text can never smuggle raw ICS" do
    test "ICS metacharacters in the description stay inert TEXT" do
      ics = Render.feed([timed_event(description: "X;Y,Z\nBEGIN:VEVENT")])
      unfolded = unfold(ics)

      assert unfolded =~ "DESCRIPTION:X\\;Y\\,Z\\nBEGIN:VEVENT"

      # Exactly ONE VEVENT — the injected component never becomes a line.
      begin_lines = physical_lines(ics) |> Enum.count(&(&1 == "BEGIN:VEVENT"))
      assert begin_lines == 1
    end

    test "a newline in any TEXT field becomes the two-character \\n escape" do
      lines = Render.feed([timed_event(title: "A\nB:INJECTED")]) |> unfold() |> physical_lines()
      assert "SUMMARY:A\\nB:INJECTED" in lines
      refute Enum.any?(lines, &(&1 == "B:INJECTED"))
    end

    test "backslashes are escaped first (no double-unescape gadget)" do
      lines =
        Render.feed([timed_event(title: "a\\b", location: "c\\;d")])
        |> unfold()
        |> physical_lines()

      assert "SUMMARY:a\\\\b" in lines
      assert "LOCATION:c\\\\\\;d" in lines
    end

    test "a CR can never reach the wire raw" do
      ics = Render.feed([timed_event(title: "a\rb")])
      refute unfold(ics) =~ "a\rb"
    end
  end

  describe "line folding" do
    test "long lines fold at 75 octets with CRLF + single space and unfold losslessly" do
      title = String.duplicate("a", 200)
      ics = Render.feed([timed_event(title: title)])

      for line <- physical_lines(ics) do
        assert byte_size(line) <= 75
      end

      assert unfold(ics) =~ "SUMMARY:" <> title
    end

    test "folding never splits a UTF-8 sequence" do
      # 2-byte chars arranged so a naive 75-octet cut would land mid-codepoint.
      title = "x" <> String.duplicate("ü", 100)
      ics = Render.feed([timed_event(title: title)])

      for line <- physical_lines(ics) do
        assert byte_size(line) <= 75
        assert String.valid?(line)
      end

      assert unfold(ics) =~ "SUMMARY:" <> title
    end

    test "folded continuation lines carry exactly one leading space" do
      title = String.duplicate("b", 300)
      ics = Render.feed([timed_event(title: title)])

      [_first | continuations] =
        ics
        |> String.split("\r\n", trim: true)
        |> Enum.filter(&(String.starts_with?(&1, "SUMMARY:") or String.starts_with?(&1, " ")))

      assert continuations != []

      for cont <- continuations do
        assert String.starts_with?(cont, " ")
        refute String.starts_with?(cont, "  ")
      end
    end
  end
end
