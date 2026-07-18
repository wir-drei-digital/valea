defmodule Valea.Calendar.LocalTest do
  use ExUnit.Case, async: true

  alias Valea.Calendar.Local
  alias Valea.Calendar.Local.Event

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "valea-cal-local-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "sources/calendar/valea/events"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp events_dir(root), do: Path.join(root, "sources/calendar/valea/events")

  defp write_event!(root, filename, bytes) do
    path = Path.join(events_dir(root), filename)
    File.write!(path, bytes)
    path
  end

  defp event_file(fields, body \\ "") do
    lines = Enum.map_join(fields, "", fn {k, v} -> "#{k}: #{v}\n" end)
    "---\n" <> lines <> "---\n" <> body
  end

  defp valid_timed(extra \\ [], body \\ "") do
    event_file(
      [{"title", ~s("Coffee with Priya")}, {"start", "2026-07-21T09:30:00+02:00"}] ++ extra,
      body
    )
  end

  defp sole_invalid_reason(root) do
    assert %{valid: [], invalid: [%{reason: reason}]} = Local.list(root)
    reason
  end

  describe "valid_name?/1" do
    test "accepts the grammar ^[a-z0-9][a-z0-9._-]{0,79}$" do
      assert Local.valid_name?("a")
      assert Local.valid_name?("9")
      assert Local.valid_name?("standup")
      assert Local.valid_name?("team-sync.v2")
      assert Local.valid_name?("a.b_c-d")
      assert Local.valid_name?("a" <> String.duplicate("x", 79))
    end

    test "rejects separators, traversal, leading dot, case, length" do
      refute Local.valid_name?("")
      refute Local.valid_name?("../x")
      refute Local.valid_name?("a/b")
      refute Local.valid_name?("a\\b")
      refute Local.valid_name?(".hidden")
      refute Local.valid_name?("-lead")
      refute Local.valid_name?("_lead")
      refute Local.valid_name?("Foo")
      refute Local.valid_name?("UPPER")
      refute Local.valid_name?("a b")
      refute Local.valid_name?("café")
      refute Local.valid_name?("a\n")
      refute Local.valid_name?("a" <> String.duplicate("x", 80))
    end

    test "rejects any .. sequence" do
      refute Local.valid_name?("a..b")
      refute Local.valid_name?("a..")
    end
  end

  describe "uid/1" do
    test "is valea-<hash16 of basename incl. .md>@valea.local" do
      hash16 =
        :crypto.hash(:sha256, "standup.md")
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)

      assert Local.uid("standup") == "valea-" <> hash16 <> "@valea.local"
    end

    test "is stable across edits (name-only) and changes on rename" do
      assert Local.uid("standup") == Local.uid("standup")
      refute Local.uid("standup") == Local.uid("standup2")
    end
  end

  describe "list/1 — valid events" do
    test "parses a timed event, offset preserved, UTC-comparable", %{root: root} do
      write_event!(
        root,
        "coffee.md",
        event_file(
          [
            {"title", ~s("Coffee with Priya")},
            {"start", "2026-07-21T09:30:00+02:00"},
            {"end", "2026-07-21T10:00:00+02:00"},
            {"location", ~s("Café Anton")}
          ],
          "Agenda: follow up.\n"
        )
      )

      assert %{valid: [%Event{} = event], invalid: []} = Local.list(root)

      assert event.name == "coffee"
      assert event.path == "sources/calendar/valea/events/coffee.md"
      assert event.title == "Coffee with Priya"
      assert event.all_day == false
      assert event.location == "Café Anton"
      assert event.status == "confirmed"
      assert event.description == "Agenda: follow up."

      assert DateTime.compare(event.start, ~U[2026-07-21 07:30:00Z]) == :eq
      assert DateTime.compare(Map.fetch!(event, :end), ~U[2026-07-21 08:00:00Z]) == :eq
      # Offset preserved from the file, not collapsed to UTC.
      assert event.start.utc_offset + event.start.std_offset == 7200
      assert DateTime.to_iso8601(event.start) == "2026-07-21T09:30:00+02:00"
    end

    test "end omitted defaults to start + 1 hour", %{root: root} do
      write_event!(root, "standup.md", valid_timed())

      assert %{valid: [event], invalid: []} = Local.list(root)
      assert DateTime.compare(Map.fetch!(event, :end), ~U[2026-07-21 08:30:00Z]) == :eq
    end

    test "a Z-offset start parses", %{root: root} do
      write_event!(
        root,
        "utc.md",
        event_file([{"title", ~s("U")}, {"start", "2026-07-21T09:30:00Z"}])
      )

      assert %{valid: [event], invalid: []} = Local.list(root)
      assert DateTime.compare(event.start, ~U[2026-07-21 09:30:00Z]) == :eq
    end

    test "all-day event: plain dates, exclusive end", %{root: root} do
      write_event!(
        root,
        "retreat.md",
        event_file([
          {"title", ~s("Retreat")},
          {"start", "2026-07-21"},
          {"end", "2026-07-23"},
          {"all_day", "true"}
        ])
      )

      assert %{valid: [event], invalid: []} = Local.list(root)
      assert event.all_day == true
      assert event.start == ~D[2026-07-21]
      assert Map.fetch!(event, :end) == ~D[2026-07-23]
    end

    test "all-day end omitted defaults to start + 1 day", %{root: root} do
      write_event!(
        root,
        "day.md",
        event_file([{"title", ~s("Day off")}, {"start", "2026-07-21"}, {"all_day", "true"}])
      )

      assert %{valid: [event], invalid: []} = Local.list(root)
      assert event.start == ~D[2026-07-21]
      assert Map.fetch!(event, :end) == ~D[2026-07-22]
    end

    test "status parses; default confirmed", %{root: root} do
      write_event!(root, "a.md", valid_timed([{"status", "tentative"}]))
      write_event!(root, "b.md", valid_timed([{"status", "cancelled"}]))
      write_event!(root, "c.md", valid_timed())

      assert %{valid: [a, b, c], invalid: []} = Local.list(root)
      assert a.status == "tentative"
      assert b.status == "cancelled"
      assert c.status == "confirmed"
    end

    test "body may contain newlines and tabs", %{root: root} do
      write_event!(root, "notes.md", valid_timed([], "line one\n\tindented\nline three\n"))

      assert %{valid: [event], invalid: []} = Local.list(root)
      assert event.description == "line one\n\tindented\nline three"
    end

    test "body up to 16384 bytes is accepted", %{root: root} do
      write_event!(root, "big.md", valid_timed([], String.duplicate("a", 16_384)))
      assert %{valid: [_event], invalid: []} = Local.list(root)
    end

    test "a 500-char multi-byte title is accepted (chars, not bytes)", %{root: root} do
      title = String.duplicate("ü", 500)

      write_event!(
        root,
        "long.md",
        event_file([{"title", ~s("#{title}")}, {"start", "2026-07-21T09:30:00+02:00"}])
      )

      assert %{valid: [event], invalid: []} = Local.list(root)
      assert event.title == title
    end

    test "mtime is the file's lstat mtime as UTC DateTime (seconds)", %{root: root} do
      path = write_event!(root, "touched.md", valid_timed())
      posix = DateTime.to_unix(~U[2026-07-18 09:30:00Z])
      File.touch!(path, posix)

      assert %{valid: [event], invalid: []} = Local.list(root)
      assert event.mtime == ~U[2026-07-18 09:30:00Z]
    end

    test "valid events come back sorted by name", %{root: root} do
      write_event!(root, "zulu.md", valid_timed())
      write_event!(root, "alpha.md", valid_timed())

      assert %{valid: [%{name: "alpha"}, %{name: "zulu"}]} = Local.list(root)
    end

    test "an empty or missing events dir lists empty", %{root: root} do
      assert %{valid: [], invalid: []} = Local.list(root)
      File.rm_rf!(Path.join(root, "sources"))
      assert %{valid: [], invalid: []} = Local.list(root)
    end

    test "dotfiles (.gitkeep) are skipped, not listed invalid", %{root: root} do
      File.write!(Path.join(events_dir(root), ".gitkeep"), "")
      assert %{valid: [], invalid: []} = Local.list(root)
    end
  end

  describe "list/1 — fail-closed validation" do
    test "unknown frontmatter keys reject", %{root: root} do
      write_event!(root, "x.md", valid_timed([{"color", ~s("red")}]))
      assert sole_invalid_reason(root) =~ "unknown frontmatter field"
    end

    test "description as a frontmatter key rejects (body IS the description)", %{root: root} do
      write_event!(root, "x.md", valid_timed([{"description", ~s("nope")}]))
      assert sole_invalid_reason(root) =~ "unknown frontmatter field"
    end

    test "title is required and must be non-empty", %{root: root} do
      write_event!(root, "x.md", event_file([{"start", "2026-07-21T09:30:00+02:00"}]))
      assert sole_invalid_reason(root) =~ "title"
    end

    test "empty title rejects", %{root: root} do
      write_event!(
        root,
        "x.md",
        event_file([{"title", ~s("")}, {"start", "2026-07-21T09:30:00+02:00"}])
      )

      assert sole_invalid_reason(root) =~ "title"
    end

    test "non-string title rejects", %{root: root} do
      write_event!(
        root,
        "x.md",
        event_file([{"title", "500"}, {"start", "2026-07-21T09:30:00+02:00"}])
      )

      assert sole_invalid_reason(root) =~ "title"
    end

    test "a 501-char title rejects", %{root: root} do
      title = String.duplicate("a", 501)

      write_event!(
        root,
        "x.md",
        event_file([{"title", ~s("#{title}")}, {"start", "2026-07-21T09:30:00+02:00"}])
      )

      assert sole_invalid_reason(root) =~ "title"
    end

    test "control character in title rejects", %{root: root} do
      write_event!(
        root,
        "x.md",
        event_file([{"title", ~s("a\tb")}, {"start", "2026-07-21T09:30:00+02:00"}])
      )

      assert sole_invalid_reason(root) =~ "control character"
    end

    test "control character in location rejects", %{root: root} do
      write_event!(root, "x.md", valid_timed([{"location", ~s("a\\tb")}]))
      assert sole_invalid_reason(root) =~ "control character"
    end

    test "body with a bare CR rejects; other C0 rejects", %{root: root} do
      write_event!(root, "x.md", valid_timed([], "line one\r\nline two\n"))
      assert sole_invalid_reason(root) =~ "control character"

      File.rm!(Path.join(events_dir(root), "x.md"))
      write_event!(root, "y.md", valid_timed([], "bad" <> <<0x01>> <> "byte\n"))
      assert sole_invalid_reason(root) =~ "control character"
    end

    test "body over 16384 bytes rejects", %{root: root} do
      write_event!(root, "x.md", valid_timed([], String.duplicate("a", 16_385)))
      assert sole_invalid_reason(root) =~ "body"
    end

    test "start is required", %{root: root} do
      write_event!(root, "x.md", event_file([{"title", ~s("T")}]))
      assert sole_invalid_reason(root) =~ "start"
    end

    test "timed start without offset rejects", %{root: root} do
      write_event!(
        root,
        "x.md",
        event_file([{"title", ~s("T")}, {"start", "2026-07-21T09:30:00"}])
      )

      assert sole_invalid_reason(root) =~ "offset"
    end

    test "timed start as a bare date rejects", %{root: root} do
      write_event!(root, "x.md", event_file([{"title", ~s("T")}, {"start", "2026-07-21"}]))
      assert sole_invalid_reason(root) =~ "start"
    end

    test "garbage start rejects", %{root: root} do
      write_event!(root, "x.md", event_file([{"title", ~s("T")}, {"start", "not-a-date"}]))
      assert sole_invalid_reason(root) =~ "start"
    end

    test "start == end rejects (timed)", %{root: root} do
      write_event!(
        root,
        "x.md",
        valid_timed([{"end", "2026-07-21T09:30:00+02:00"}])
      )

      assert sole_invalid_reason(root) =~ "before"
    end

    test "start > end rejects (timed)", %{root: root} do
      write_event!(root, "x.md", valid_timed([{"end", "2026-07-21T09:00:00+02:00"}]))
      assert sole_invalid_reason(root) =~ "before"
    end

    test "all-day with datetime values rejects", %{root: root} do
      write_event!(
        root,
        "x.md",
        event_file([
          {"title", ~s("T")},
          {"start", "2026-07-21T09:30:00+02:00"},
          {"all_day", "true"}
        ])
      )

      assert sole_invalid_reason(root) =~ "date"
    end

    test "all-day equal start/end rejects (end is exclusive, strictly after)", %{root: root} do
      write_event!(
        root,
        "x.md",
        event_file([
          {"title", ~s("T")},
          {"start", "2026-07-21"},
          {"end", "2026-07-21"},
          {"all_day", "true"}
        ])
      )

      assert sole_invalid_reason(root) =~ "after"
    end

    test "all-day end before start rejects", %{root: root} do
      write_event!(
        root,
        "x.md",
        event_file([
          {"title", ~s("T")},
          {"start", "2026-07-21"},
          {"end", "2026-07-20"},
          {"all_day", "true"}
        ])
      )

      assert sole_invalid_reason(root) =~ "after"
    end

    test "non-boolean all_day rejects", %{root: root} do
      write_event!(
        root,
        "x.md",
        event_file([{"title", ~s("T")}, {"start", "2026-07-21"}, {"all_day", ~s("maybe")}])
      )

      assert sole_invalid_reason(root) =~ "all_day"
    end

    test "unknown status rejects", %{root: root} do
      write_event!(root, "x.md", valid_timed([{"status", "busy"}]))
      assert sole_invalid_reason(root) =~ "status"
    end

    test "missing frontmatter rejects", %{root: root} do
      write_event!(root, "x.md", "just a body, no frontmatter\n")
      assert sole_invalid_reason(root) =~ "frontmatter"
    end

    test "unterminated frontmatter rejects", %{root: root} do
      write_event!(root, "x.md", "---\ntitle: \"T\"\n")
      assert sole_invalid_reason(root) =~ "frontmatter"
    end

    test "non-UTF8 content rejects", %{root: root} do
      write_event!(root, "x.md", "---\ntitle: \"T\"\n---\n" <> <<0xFF, 0xFE>>)
      assert sole_invalid_reason(root) =~ "UTF-8"
    end

    test "a symlink is rejected unread", %{root: root} do
      target = Path.join(root, "outside.md")
      File.write!(target, valid_timed())
      File.ln_s!(target, Path.join(events_dir(root), "linked.md"))

      assert %{valid: [], invalid: [%{name: "linked.md", reason: reason}]} = Local.list(root)
      assert reason =~ "link"
    end

    test "a hard-linked file is rejected unread", %{root: root} do
      path = write_event!(root, "orig.md", valid_timed())
      File.ln!(path, Path.join(root, "hardlink-elsewhere.md"))

      assert %{valid: [], invalid: [%{name: "orig.md", reason: reason}]} = Local.list(root)
      assert reason =~ "link"
    end

    test "a non-md or invalidly named entry is listed invalid", %{root: root} do
      File.write!(Path.join(events_dir(root), "notes.txt"), "hi")
      File.write!(Path.join(events_dir(root), "UPPER.md"), valid_timed())
      File.write!(Path.join(events_dir(root), "has space.md"), valid_timed())

      assert %{valid: [], invalid: invalid} = Local.list(root)

      assert Enum.map(invalid, & &1.name) |> Enum.sort() == [
               "UPPER.md",
               "has space.md",
               "notes.txt"
             ]

      assert Enum.all?(invalid, &(&1.reason =~ "name"))
    end

    test "a directory named like an event is listed invalid", %{root: root} do
      File.mkdir_p!(Path.join(events_dir(root), "dir.md"))
      assert sole_invalid_reason(root) =~ "regular file"
    end

    test "invalid files never suppress valid ones", %{root: root} do
      write_event!(root, "good.md", valid_timed())
      write_event!(root, "bad.md", valid_timed([{"color", ~s("red")}]))

      assert %{valid: [%{name: "good"}], invalid: [%{name: "bad.md"}]} = Local.list(root)
    end

    test "an events dir that is itself a symlink lists nothing", %{root: root} do
      outside = Path.join(root, "outside-events")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "evil.md"), valid_timed())
      File.rm_rf!(events_dir(root))
      File.ln_s!(outside, events_dir(root))

      assert %{valid: [], invalid: []} = Local.list(root)
    end
  end

  describe "write/4" do
    test "create writes a valid file that round-trips through list", %{root: root} do
      assert {:ok, "sources/calendar/valea/events/coffee.md"} =
               Local.write(
                 root,
                 "coffee",
                 %{
                   title: "Coffee; with, Priya",
                   start: "2026-07-21T09:30:00+02:00",
                   end: "2026-07-21T10:00:00+02:00",
                   location: "Café \"Anton\"",
                   description: "Agenda: plan.\nSecond line."
                 },
                 :create
               )

      assert %{valid: [event], invalid: []} = Local.list(root)
      assert event.title == "Coffee; with, Priya"
      assert event.location == "Café \"Anton\""
      assert event.description == "Agenda: plan.\nSecond line."
      assert DateTime.compare(event.start, ~U[2026-07-21 07:30:00Z]) == :eq
    end

    test "create refuses an existing name", %{root: root} do
      attrs = %{title: "T", start: "2026-07-21T09:30:00+02:00"}
      assert {:ok, _path} = Local.write(root, "standup", attrs, :create)
      assert {:error, :exists} = Local.write(root, "standup", attrs, :create)
    end

    test "create refuses a name occupied by a symlink", %{root: root} do
      File.ln_s!(Path.join(root, "nowhere"), Path.join(events_dir(root), "standup.md"))

      assert {:error, :exists} =
               Local.write(
                 root,
                 "standup",
                 %{title: "T", start: "2026-07-21T09:30:00+02:00"},
                 :create
               )
    end

    test "update requires an existing file and replaces it", %{root: root} do
      attrs = %{title: "T", start: "2026-07-21T09:30:00+02:00"}
      assert {:error, :not_found} = Local.write(root, "standup", attrs, :update)

      assert {:ok, _path} = Local.write(root, "standup", attrs, :create)
      assert {:ok, _path} = Local.write(root, "standup", %{attrs | title: "T2"}, :update)

      assert %{valid: [%{title: "T2"}], invalid: []} = Local.list(root)
    end

    test "invalid attrs reject fail-closed, nothing written", %{root: root} do
      assert {:error, {:invalid, reason}} =
               Local.write(
                 root,
                 "x",
                 %{title: "T", start: "2026-07-21T09:30:00+02:00", status: "busy"},
                 :create
               )

      assert reason =~ "status"
      refute File.exists?(Path.join(events_dir(root), "x.md"))
    end

    test "control characters in attrs reject (never laundered)", %{root: root} do
      assert {:error, {:invalid, reason}} =
               Local.write(
                 root,
                 "x",
                 %{title: "a\nb", start: "2026-07-21T09:30:00+02:00"},
                 :create
               )

      assert reason =~ "control character"
      refute File.exists?(Path.join(events_dir(root), "x.md"))
    end

    test "invalid name rejects before any path construction", %{root: root} do
      for name <- ["../x", "a/b", ".hidden", "Foo", "a..b", "a" <> String.duplicate("x", 80)] do
        assert {:error, {:invalid, reason}} =
                 Local.write(
                   root,
                   name,
                   %{title: "T", start: "2026-07-21T09:30:00+02:00"},
                   :create
                 )

        assert reason =~ "name"
      end

      refute File.exists?(Path.join(root, "x"))
    end

    test "an all-day event with inclusive attrs round-trips", %{root: root} do
      assert {:ok, _path} =
               Local.write(
                 root,
                 "retreat",
                 %{title: "Retreat", start: "2026-07-21", end: "2026-07-23", all_day: true},
                 :create
               )

      assert %{valid: [event], invalid: []} = Local.list(root)
      assert event.all_day == true
      assert event.start == ~D[2026-07-21]
      assert Map.fetch!(event, :end) == ~D[2026-07-23]
    end

    test "uid is stable across an update, new after a rename", %{root: root} do
      attrs = %{title: "T", start: "2026-07-21T09:30:00+02:00"}
      assert {:ok, _} = Local.write(root, "standup", attrs, :create)
      uid_before = Local.uid("standup")

      assert {:ok, _} = Local.write(root, "standup", %{attrs | title: "Renamed title"}, :update)
      assert Local.uid("standup") == uid_before

      # A rename is intentionally a new event: new name, new UID.
      refute Local.uid("standup-moved") == uid_before
    end
  end

  describe "delete/2" do
    test "deletes an existing event", %{root: root} do
      assert {:ok, _} =
               Local.write(
                 root,
                 "standup",
                 %{title: "T", start: "2026-07-21T09:30:00+02:00"},
                 :create
               )

      assert :ok = Local.delete(root, "standup")
      refute File.exists?(Path.join(events_dir(root), "standup.md"))
      assert {:error, :not_found} = Local.delete(root, "standup")
    end

    test "invalid names are not found, never path-constructed", %{root: root} do
      assert {:error, :not_found} = Local.delete(root, "../x")
      assert {:error, :not_found} = Local.delete(root, ".hidden")
    end
  end
end
