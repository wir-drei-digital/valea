# A scripted `Valea.Calendar.Fetch` double (get/3 — the PRODUCTION arity),
# injected via the `Application.get_env(:valea, :calendar_fetch, ...)` seam
# BEFORE the workspace opens, so the Runtime-started engines and the
# doctor's probe both use it. Unscripted URLs answer `:unchanged` (inert).
defmodule Valea.Api.CalendarRpcTest.FakeFetch do
  def start_link do
    Agent.start_link(fn -> %{scripts: %{}} end, name: __MODULE__)
  end

  def script(url, responses) when is_list(responses) do
    Agent.update(__MODULE__, fn state -> put_in(state.scripts[url], responses) end)
  end

  def get(url, _etag, _last_modified) do
    response =
      Agent.get_and_update(__MODULE__, fn state ->
        case Map.get(state.scripts, url, []) do
          [] -> {:unchanged, state}
          [last] -> {last, state}
          [head | rest] -> {head, put_in(state.scripts[url], rest)}
        end
      end)

    case response do
      {:body, bytes} -> {:ok, %{body: bytes, etag: nil, last_modified: nil}}
      other -> other
    end
  end
end

defmodule Valea.Api.CalendarRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.Api.CalendarRpcTest.FakeFetch
  alias Valea.Calendar.Store
  alias Valea.Workspace.Manager

  @status_fields ["sources", "feedEnabled", "valeaEventCount", "configInvalid"]

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()

    # Engines read this at init, so it must be set before the workspace opens.
    {:ok, _} = FakeFetch.start_link()
    Application.put_env(:valea, :calendar_fetch, FakeFetch)

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
      Application.delete_env(:valea, :calendar_fetch)
    end)

    {:ok, ws} = Manager.create("W")
    %{"data" => %{"generation" => generation}} = rpc("get_workspace", %{})

    %{workspace: ws.path, generation: generation}
  end

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  # -- fixtures ---------------------------------------------------------------

  defp url(slug), do: "https://feeds.example.com/#{slug}.ics"

  defp config_path(workspace), do: Path.join(workspace, "config/calendar.yaml")

  defp setup_source!(generation, slug) do
    assert %{"success" => true, "data" => %{"saved" => true}} =
             rpc(
               "setup_calendar_source",
               %{"source" => slug, "name" => String.capitalize(slug), "generation" => generation},
               ["saved"]
             )

    slug
  end

  defp set_url!(slug, generation) do
    assert %{"success" => true, "data" => %{"accepted" => true}} =
             rpc(
               "set_calendar_source_url",
               %{"source" => slug, "url" => url(slug), "generation" => generation},
               ["accepted"]
             )

    :ok
  end

  # Waits until `calendar_status` lists a non-inactive entry for `slug` — a
  # fresh `setup_calendar_source` self-activates its engine asynchronously
  # (the supervisor rehash), so an immediate follow-up request can race it.
  defp await_source!(slug) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case rpc("calendar_status", %{}, @status_fields) do
        %{"success" => true, "data" => %{"sources" => sources}} ->
          case Enum.find(sources, &(&1["source"] == slug)) do
            %{"state" => "inactive"} ->
              Process.sleep(5)
              {:cont, nil}

            %{} = found ->
              {:halt, found}

            nil ->
              Process.sleep(5)
              {:cont, nil}
          end
      end
    end)
  end

  defp status_entry(slug) do
    %{"success" => true, "data" => %{"sources" => sources}} =
      rpc("calendar_status", %{}, @status_fields)

    Enum.find(sources, &(&1["source"] == slug))
  end

  defp write_valea_event!(workspace, name, bytes) do
    dir = Path.join([workspace, "sources", "calendar", "valea", "events"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name <> ".md"), bytes)
  end

  # Plants external occurrence rows straight into the index plus one view
  # file per row (the engine-owned surfaces `list_calendar_events` reads):
  # exercising the query path needs controlled rows, not a full sync.
  defp plant_rows!(workspace, slug, rows) do
    views_dir = Path.join([workspace, "sources", "calendar", slug, "views", "events"])
    File.mkdir_p!(views_dir)

    db_rows =
      Enum.map(rows, fn row ->
        file = "ev-#{row.uid}.md"
        File.write!(Path.join(views_dir, file), "---\nuid: #{row.uid}\n---\n" <> row.body)

        row
        |> Map.drop([:body])
        |> Map.put(:view_path, Path.join(["sources", "calendar", slug, "views", "events", file]))
      end)

    Store.replace_source!(slug, db_rows, "test-rev", nil, nil)
  end

  defp timed_row(uid, occ_start, occ_end, summary, opts \\ []) do
    %{
      uid: uid,
      all_day: false,
      occ_start: occ_start,
      occ_end: occ_end,
      summary: summary,
      location: Keyword.get(opts, :location),
      status: Keyword.get(opts, :status, "confirmed"),
      body: Keyword.get(opts, :body, "")
    }
  end

  defp all_day_row(uid, occ_start, occ_end, summary, opts \\ []) do
    %{
      uid: uid,
      all_day: true,
      occ_start: occ_start,
      occ_end: occ_end,
      summary: summary,
      location: Keyword.get(opts, :location),
      status: Keyword.get(opts, :status, "confirmed"),
      body: Keyword.get(opts, :body, "")
    }
  end

  defp list_events!(from, to, zone) do
    assert %{"success" => true, "data" => %{"events" => events}} =
             rpc(
               "list_calendar_events",
               %{"from" => from, "to" => to, "zone" => zone},
               ["events"]
             )

    events
  end

  defp minimal_ics do
    Enum.join(
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Valea Test//EN",
        "BEGIN:VEVENT",
        "UID:a@x",
        "DTSTART:20260720T100000Z",
        "DTEND:20260720T110000Z",
        "SUMMARY:One",
        "END:VEVENT",
        "END:VCALENDAR"
      ],
      "\r\n"
    ) <> "\r\n"
  end

  # -- calendar_status ----------------------------------------------------------

  describe "calendar_status" do
    test "template workspace: empty sources, feed disabled, zero valea events, no config_invalid" do
      assert %{"success" => true, "data" => data} = rpc("calendar_status", %{}, @status_fields)

      assert data["sources"] == []
      assert data["feedEnabled"] == false
      assert data["valeaEventCount"] == 0
      assert data["configInvalid"] == nil
    end

    test "lists a valid, running source plus an invalid-config entry, sorted by source", %{
      workspace: workspace,
      generation: generation
    } do
      setup_source!(generation, "zeta")
      await_source!("zeta")

      # Hand-append a structurally-invalid entry AFTER the last setup call
      # (`Settings.put_source/3` re-renders the whole file from valid
      # entries, so an earlier injection would be dropped on rewrite).
      path = config_path(workspace)

      File.write!(
        path,
        String.replace(File.read!(path), "sources:\n", "sources:\n  alpha:\n    name: 7\n")
      )

      assert %{"success" => true, "data" => %{"sources" => sources}} =
               rpc("calendar_status", %{}, @status_fields)

      by_source = Map.new(sources, &{&1["source"], &1})

      assert by_source["zeta"]["valid"] == true
      assert by_source["zeta"]["state"] in ["inactive", "idle"]
      assert by_source["zeta"]["url_present"] == false

      assert by_source["alpha"] == %{
               "source" => "alpha",
               "valid" => false,
               "state" => "invalid_config",
               "reason" => by_source["alpha"]["reason"]
             }

      assert is_binary(by_source["alpha"]["reason"])
      assert Enum.map(sources, & &1["source"]) == Enum.sort(Enum.map(sources, & &1["source"]))
    end

    test "a whole-file-invalid config: sources [] + config_invalid reason, action still succeeds",
         %{workspace: workspace} do
      File.write!(config_path(workspace), "version: 2\nsources: {}\n")

      assert %{"success" => true, "data" => data} = rpc("calendar_status", %{}, @status_fields)

      assert data["sources"] == []
      assert is_binary(data["configInvalid"])
      assert data["configInvalid"] =~ "version"
      assert data["feedEnabled"] == false
    end

    test "counts valid valea events", %{workspace: workspace} do
      write_valea_event!(workspace, "coffee", """
      ---
      title: "Coffee"
      start: 2026-07-21T09:30:00+02:00
      ---
      """)

      assert %{"success" => true, "data" => %{"valeaEventCount" => 1}} =
               rpc("calendar_status", %{}, @status_fields)
    end
  end

  # -- setup_calendar_source ----------------------------------------------------

  describe "setup_calendar_source" do
    test "happy path writes config and starts an engine with url_present false", %{
      workspace: workspace,
      generation: generation
    } do
      setup_source!(generation, "work")
      assert File.read!(config_path(workspace)) =~ "work:"

      entry = await_source!("work")
      assert entry["valid"] == true
      assert entry["url_present"] == false
    end

    test "a stale generation surfaces workspace_changed and does not write", %{
      workspace: workspace,
      generation: generation
    } do
      before = File.read!(config_path(workspace))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "setup_calendar_source",
                 %{"source" => "work", "name" => "Work", "generation" => generation - 1},
                 ["saved"]
               )

      assert inspect(errors) =~ "workspace_changed"
      assert File.read!(config_path(workspace)) == before
    end
  end

  # -- slug grammar (shared across actions) -------------------------------------

  describe "slug grammar" do
    test "setup/set-url/remove/purge/sync/doctor reject bad slugs incl. the reserved valea before any I/O",
         %{workspace: workspace, generation: generation} do
      before = File.read!(config_path(workspace))

      for slug <- ["../x", "valea", "UPPER", "a b", "/etc"] do
        calls = [
          {"setup_calendar_source",
           %{"source" => slug, "name" => "X", "generation" => generation}, ["saved"]},
          {"set_calendar_source_url",
           %{"source" => slug, "url" => url("x"), "generation" => generation}, ["accepted"]},
          {"remove_calendar_source", %{"source" => slug, "generation" => generation},
           ["removed"]},
          {"purge_calendar_source_files",
           %{"source" => slug, "confirmation" => slug, "generation" => generation}, ["purged"]},
          {"calendar_sync_now", %{"source" => slug, "generation" => generation}, ["started"]},
          {"calendar_doctor", %{"source" => slug, "generation" => generation}, ["ok", "checks"]}
        ]

        for {action, input, fields} <- calls do
          assert %{"success" => false, "errors" => errors} = rpc(action, input, fields)
          assert inspect(errors) =~ "invalid_slug", "#{action} accepted slug #{inspect(slug)}"
        end
      end

      assert File.read!(config_path(workspace)) == before
    end
  end

  # -- set_calendar_source_url --------------------------------------------------

  describe "set_calendar_source_url" do
    test "END-TO-END: setup -> engine url-less -> set URL -> url_present true + .source claimed",
         %{workspace: workspace, generation: generation} do
      setup_source!(generation, "work")
      entry = await_source!("work")
      assert entry["url_present"] == false

      source_file = Path.join([workspace, "sources", "calendar", "work", ".source"])
      refute File.exists?(source_file)

      set_url!("work", generation)

      assert status_entry("work")["url_present"] == true
      assert File.exists?(source_file)
      assert File.read!(source_file) =~ "feeds.example.com"
    end

    test "reject leg: an http:// URL after setup leaves no .source and url_present false", %{
      workspace: workspace,
      generation: generation
    } do
      setup_source!(generation, "work")
      await_source!("work")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_calendar_source_url",
                 %{
                   "source" => "work",
                   "url" => "http://feeds.example.com/work.ics",
                   "generation" => generation
                 },
                 ["accepted"]
               )

      assert inspect(errors) =~ "not_https"
      refute File.exists?(Path.join([workspace, "sources", "calendar", "work", ".source"]))
      assert status_entry("work")["url_present"] == false
    end

    test "an unparseable URL is invalid_url", %{generation: generation} do
      setup_source!(generation, "work")
      await_source!("work")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_calendar_source_url",
                 %{"source" => "work", "url" => "not a url at all", "generation" => generation},
                 ["accepted"]
               )

      assert inspect(errors) =~ "invalid_url"
    end

    test "an unknown source surfaces not_found", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_calendar_source_url",
                 %{"source" => "ghost", "url" => url("ghost"), "generation" => generation},
                 ["accepted"]
               )

      assert inspect(errors) =~ "not_found"
    end
  end

  # -- remove_calendar_source ---------------------------------------------------

  describe "remove_calendar_source" do
    test "happy path removes the config entry and stops the engine; files stay", %{
      workspace: workspace,
      generation: generation
    } do
      setup_source!(generation, "work")
      await_source!("work")
      set_url!("work", generation)

      source_dir = Path.join([workspace, "sources", "calendar", "work"])
      assert File.dir?(source_dir)

      assert %{"success" => true, "data" => %{"removed" => true}} =
               rpc("remove_calendar_source", %{"source" => "work", "generation" => generation}, [
                 "removed"
               ])

      assert status_entry("work") == nil
      assert File.dir?(source_dir)
    end
  end

  # -- purge_calendar_source_files ----------------------------------------------

  describe "purge_calendar_source_files" do
    test "requires the confirmation to exactly match the slug", %{generation: generation} do
      setup_source!(generation, "work")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "purge_calendar_source_files",
                 %{"source" => "work", "confirmation" => "not-work", "generation" => generation},
                 ["purged"]
               )

      assert inspect(errors) =~ "confirmation_mismatch"
    end

    test "refuses while the source is still configured", %{generation: generation} do
      setup_source!(generation, "work")
      await_source!("work")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "purge_calendar_source_files",
                 %{"source" => "work", "confirmation" => "work", "generation" => generation},
                 ["purged"]
               )

      assert inspect(errors) =~ "still_configured"
    end

    test "refuses an unconfigured slug that never existed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "purge_calendar_source_files",
                 %{"source" => "ghost", "confirmation" => "ghost", "generation" => generation},
                 ["purged"]
               )

      assert inspect(errors) =~ "not_found"
    end

    test "succeeds once the source is removed from config: files + index rows gone", %{
      workspace: workspace,
      generation: generation
    } do
      setup_source!(generation, "work")
      await_source!("work")
      set_url!("work", generation)

      plant_rows!(workspace, "work", [
        timed_row("t1", "2026-07-20T10:00:00Z", "2026-07-20T11:00:00Z", "Standup")
      ])

      assert Store.occurrence_count("work") == 1

      assert %{"success" => true} =
               rpc("remove_calendar_source", %{"source" => "work", "generation" => generation}, [
                 "removed"
               ])

      assert %{"success" => true, "data" => %{"purged" => true}} =
               rpc(
                 "purge_calendar_source_files",
                 %{"source" => "work", "confirmation" => "work", "generation" => generation},
                 ["purged"]
               )

      refute File.exists?(Path.join([workspace, "sources", "calendar", "work"]))
      assert Store.occurrence_count("work") == 0
    end
  end

  # -- calendar_sync_now --------------------------------------------------------

  describe "calendar_sync_now" do
    test "happy path returns started true", %{generation: generation} do
      setup_source!(generation, "work")
      await_source!("work")
      set_url!("work", generation)

      FakeFetch.script(url("work"), [{:body, minimal_ics()}])

      assert %{"success" => true, "data" => %{"started" => true}} =
               rpc("calendar_sync_now", %{"source" => "work", "generation" => generation}, [
                 "started"
               ])
    end

    test "an unknown source surfaces not_found", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc("calendar_sync_now", %{"source" => "ghost", "generation" => generation}, [
                 "started"
               ])

      assert inspect(errors) =~ "not_found"
    end

    test "a URL-less engine surfaces no_url", %{generation: generation} do
      setup_source!(generation, "work")
      await_source!("work")

      assert %{"success" => false, "errors" => errors} =
               rpc("calendar_sync_now", %{"source" => "work", "generation" => generation}, [
                 "started"
               ])

      assert inspect(errors) =~ "no_url"
    end
  end

  # -- calendar_doctor ----------------------------------------------------------

  describe "calendar_doctor" do
    test "returns the gated check pipeline; a URL-less source fails url_present", %{
      generation: generation
    } do
      setup_source!(generation, "work")
      await_source!("work")

      assert %{"success" => true, "data" => %{"ok" => false, "checks" => checks}} =
               rpc("calendar_doctor", %{"source" => "work", "generation" => generation}, [
                 "ok",
                 "checks"
               ])

      assert Enum.map(checks, & &1["id"]) == [
               "config_present",
               "url_present",
               "reachable",
               "parse_ok",
               "freshness",
               "feed_endpoint"
             ]

      by_id = Map.new(checks, &{&1["id"], &1})
      assert by_id["config_present"]["status"] == "ok"
      assert by_id["url_present"]["status"] == "failed"
      assert is_binary(by_id["url_present"]["remedy"])
      assert by_id["reachable"]["status"] == "unknown"
      assert by_id["parse_ok"]["status"] == "unknown"
      assert by_id["freshness"]["status"] == "unknown"
    end

    test "never echoes the feed URL host or the feed token anywhere in its output", %{
      generation: generation
    } do
      setup_source!(generation, "work")
      await_source!("work")
      set_url!("work", generation)

      assert %{"success" => true, "data" => %{"token" => token}} =
               rpc("enable_calendar_feed", %{"generation" => generation}, ["token"])

      FakeFetch.script(url("work"), [{:body, minimal_ics()}])

      response =
        rpc("calendar_doctor", %{"source" => "work", "generation" => generation}, [
          "ok",
          "checks"
        ])

      assert %{"success" => true} = response

      output = inspect(response, limit: :infinity, printable_limit: :infinity)
      refute output =~ url("work")
      refute output =~ "feeds.example.com"
      refute output =~ token
    end
  end

  # -- list_calendar_events -----------------------------------------------------

  describe "list_calendar_events" do
    test "serializes the exact CalendarOccurrence wire shape (external timed, external all-day, valea)",
         %{workspace: workspace} do
      plant_rows!(workspace, "work", [
        timed_row("t1", "2026-07-20T10:00:00Z", "2026-07-20T11:00:00Z", "Standup",
          location: "Room 1",
          body: "Agenda body.\n"
        ),
        all_day_row("d1", "2026-07-22", "2026-07-23", "Offsite", status: "tentative")
      ])

      write_valea_event!(workspace, "coffee", """
      ---
      title: "Coffee with Priya"
      start: 2026-07-21T09:30:00+02:00
      end: 2026-07-21T10:00:00+02:00
      location: "Café Anton"
      ---
      Agenda: plan the workshop.
      """)

      events = list_events!("2026-07-20", "2026-07-24", "Etc/UTC")
      assert [timed, valea, all_day] = events

      assert timed == %{
               "source" => "work",
               "all_day" => false,
               "start" => "2026-07-20T10:00:00Z",
               "end" => "2026-07-20T11:00:00Z",
               "summary" => "Standup",
               "location" => "Room 1",
               "status" => "confirmed",
               "description" => "Agenda body.",
               "view_path" => "sources/calendar/work/views/events/ev-t1.md",
               "path" => nil
             }

      assert valea == %{
               "source" => "valea",
               "all_day" => false,
               "start" => "2026-07-21T07:30:00Z",
               "end" => "2026-07-21T08:00:00Z",
               "summary" => "Coffee with Priya",
               "location" => "Café Anton",
               "status" => "confirmed",
               "description" => "Agenda: plan the workshop.",
               "view_path" => nil,
               "path" => "sources/calendar/valea/events/coffee.md"
             }

      assert all_day == %{
               "source" => "work",
               "all_day" => true,
               "start" => "2026-07-22",
               "end" => "2026-07-23",
               "summary" => "Offsite",
               "location" => nil,
               "status" => "tentative",
               "description" => nil,
               "view_path" => "sources/calendar/work/views/events/ev-d1.md",
               "path" => nil
             }
    end

    test "a timed event straddling the range start is INCLUDED (overlap, not a start filter)", %{
      workspace: workspace
    } do
      plant_rows!(workspace, "work", [
        timed_row("t1", "2026-07-19T23:30:00Z", "2026-07-20T00:30:00Z", "Straddler")
      ])

      assert [%{"summary" => "Straddler"}] =
               list_events!("2026-07-20", "2026-07-21", "Etc/UTC")

      assert list_events!("2026-07-21", "2026-07-22", "Etc/UTC") == []
    end

    test "a UTC-date boundary event lands on the correct local day in a negative-offset zone", %{
      workspace: workspace
    } do
      # 2026-07-21T02:00Z is 2026-07-20 22:00 in America/New_York (UTC-4).
      plant_rows!(workspace, "work", [
        timed_row("t1", "2026-07-21T02:00:00Z", "2026-07-21T03:00:00Z", "Late dinner")
      ])

      assert [%{"summary" => "Late dinner"}] =
               list_events!("2026-07-20", "2026-07-21", "America/New_York")

      assert list_events!("2026-07-21", "2026-07-22", "America/New_York") == []
    end

    test "all-day rows overlap with an EXCLUSIVE end date", %{workspace: workspace} do
      plant_rows!(workspace, "work", [
        all_day_row("d1", "2026-07-18", "2026-07-20", "Two days")
      ])

      assert [%{"summary" => "Two days"}] = list_events!("2026-07-19", "2026-07-20", "Etc/UTC")
      assert list_events!("2026-07-20", "2026-07-21", "Etc/UTC") == []
    end

    test "orders per local day: all-day first, then timed by local start, valea merged", %{
      workspace: workspace
    } do
      plant_rows!(workspace, "work", [
        timed_row("t-later", "2026-07-20T10:00:00Z", "2026-07-20T11:00:00Z", "Later"),
        timed_row("t-earlier", "2026-07-20T08:00:00Z", "2026-07-20T08:30:00Z", "Earlier"),
        all_day_row("d1", "2026-07-20", "2026-07-21", "Allday")
      ])

      write_valea_event!(workspace, "midmorning", """
      ---
      title: "Midmorning"
      start: 2026-07-20T09:00:00+00:00
      ---
      """)

      events = list_events!("2026-07-20", "2026-07-21", "Etc/UTC")

      assert Enum.map(events, & &1["summary"]) == ["Allday", "Earlier", "Midmorning", "Later"]
    end

    test "an invalid zone is rejected — never a silent default", %{workspace: workspace} do
      plant_rows!(workspace, "work", [
        timed_row("t1", "2026-07-20T10:00:00Z", "2026-07-20T11:00:00Z", "One")
      ])

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "list_calendar_events",
                 %{"from" => "2026-07-20", "to" => "2026-07-21", "zone" => "Mars/Olympus"},
                 ["events"]
               )

      assert inspect(errors) =~ "invalid_zone"
    end

    test "unparseable from/to dates are rejected" do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "list_calendar_events",
                 %{"from" => "not-a-date", "to" => "2026-07-21", "zone" => "Etc/UTC"},
                 ["events"]
               )

      assert inspect(errors) =~ "invalid_range"
    end
  end

  # -- valea event writes -------------------------------------------------------

  describe "create_valea_event" do
    test "happy path writes the file, returns its path, and broadcasts calendar_local_changed",
         %{workspace: workspace, generation: generation} do
      Phoenix.PubSub.subscribe(Valea.PubSub, "calendar")

      assert %{"success" => true, "data" => %{"created" => true, "path" => path}} =
               rpc(
                 "create_valea_event",
                 %{
                   "name" => "coffee",
                   "title" => "Coffee",
                   "start" => "2026-07-21T09:30:00+02:00",
                   "description" => "Agenda.",
                   "generation" => generation
                 },
                 ["created", "path"]
               )

      assert path == "sources/calendar/valea/events/coffee.md"
      assert File.read!(Path.join(workspace, path)) =~ "title: \"Coffee\""
      assert_receive {:calendar_local_changed}
    end

    test "refuses an existing name", %{generation: generation} do
      input = %{
        "name" => "coffee",
        "title" => "Coffee",
        "start" => "2026-07-21T09:30:00+02:00",
        "generation" => generation
      }

      assert %{"success" => true} = rpc("create_valea_event", input, ["created", "path"])

      assert %{"success" => false, "errors" => errors} =
               rpc("create_valea_event", input, ["created", "path"])

      assert inspect(errors) =~ "exists"
    end

    test "rejects a bad name before any I/O", %{workspace: workspace, generation: generation} do
      for bad <- ["../evil", "a/b", "UPPER", ".hidden", "a..b"] do
        assert %{"success" => false, "errors" => errors} =
                 rpc(
                   "create_valea_event",
                   %{
                     "name" => bad,
                     "title" => "X",
                     "start" => "2026-07-21T09:30:00+02:00",
                     "generation" => generation
                   },
                   ["created", "path"]
                 )

        assert inspect(errors) =~ "invalid_event_name", "accepted name #{inspect(bad)}"
      end

      refute File.exists?(
               Path.join([workspace, "sources", "calendar", "valea", "events", "evil.md"])
             )
    end

    test "invalid attrs surface the validation reason with nothing on disk", %{
      workspace: workspace,
      generation: generation
    } do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_valea_event",
                 %{
                   "name" => "bad-date",
                   "title" => "X",
                   "start" => "someday soon",
                   "generation" => generation
                 },
                 ["created", "path"]
               )

      assert inspect(errors) =~ "ISO 8601"

      refute File.exists?(
               Path.join([workspace, "sources", "calendar", "valea", "events", "bad-date.md"])
             )
    end

    test "a stale generation against a running workspace refuses with nothing on disk", %{
      workspace: workspace,
      generation: generation
    } do
      # The Codex round-3 posture: the generation guard also re-runs
      # INSIDE the write serializer (`Local.write/5`'s verify hook), so a
      # stale mutation surfaces the standard workspace_changed error and
      # never touches the events tree.
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_valea_event",
                 %{
                   "name" => "stale",
                   "title" => "Stale",
                   "start" => "2026-07-21T09:30:00+02:00",
                   "generation" => generation - 1
                 },
                 ["created", "path"]
               )

      assert inspect(errors) =~ "workspace_changed"

      refute File.exists?(
               Path.join([workspace, "sources", "calendar", "valea", "events", "stale.md"])
             )
    end
  end

  describe "update_valea_event" do
    test "full-replace update of an existing event + broadcast", %{
      workspace: workspace,
      generation: generation
    } do
      write_valea_event!(workspace, "coffee", """
      ---
      title: "Coffee"
      start: 2026-07-21T09:30:00+02:00
      ---
      Old body.
      """)

      Phoenix.PubSub.subscribe(Valea.PubSub, "calendar")

      assert %{"success" => true, "data" => %{"updated" => true}} =
               rpc(
                 "update_valea_event",
                 %{
                   "name" => "coffee",
                   "title" => "Coffee (moved)",
                   "start" => "2026-07-21T10:30:00+02:00",
                   "description" => "New body.",
                   "generation" => generation
                 },
                 ["updated"]
               )

      bytes =
        File.read!(Path.join([workspace, "sources", "calendar", "valea", "events", "coffee.md"]))

      assert bytes =~ "Coffee (moved)"
      assert bytes =~ "New body."
      refute bytes =~ "Old body."
      assert_receive {:calendar_local_changed}
    end

    test "a missing name surfaces not_found", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "update_valea_event",
                 %{
                   "name" => "ghost",
                   "title" => "X",
                   "start" => "2026-07-21T09:30:00+02:00",
                   "generation" => generation
                 },
                 ["updated"]
               )

      assert inspect(errors) =~ "not_found"
    end
  end

  describe "delete_valea_event" do
    test "requires the typed confirmation to match the name", %{
      workspace: workspace,
      generation: generation
    } do
      write_valea_event!(workspace, "coffee", """
      ---
      title: "Coffee"
      start: 2026-07-21T09:30:00+02:00
      ---
      """)

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "delete_valea_event",
                 %{"name" => "coffee", "confirmation" => "tea", "generation" => generation},
                 ["deleted"]
               )

      assert inspect(errors) =~ "confirmation_mismatch"

      assert File.exists?(
               Path.join([workspace, "sources", "calendar", "valea", "events", "coffee.md"])
             )
    end

    test "happy path deletes the file and broadcasts", %{
      workspace: workspace,
      generation: generation
    } do
      write_valea_event!(workspace, "coffee", """
      ---
      title: "Coffee"
      start: 2026-07-21T09:30:00+02:00
      ---
      """)

      Phoenix.PubSub.subscribe(Valea.PubSub, "calendar")

      assert %{"success" => true, "data" => %{"deleted" => true}} =
               rpc(
                 "delete_valea_event",
                 %{"name" => "coffee", "confirmation" => "coffee", "generation" => generation},
                 ["deleted"]
               )

      refute File.exists?(
               Path.join([workspace, "sources", "calendar", "valea", "events", "coffee.md"])
             )

      assert_receive {:calendar_local_changed}
    end

    test "a missing event surfaces not_found", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "delete_valea_event",
                 %{"name" => "ghost", "confirmation" => "ghost", "generation" => generation},
                 ["deleted"]
               )

      assert inspect(errors) =~ "not_found"
    end
  end

  # -- served feed token --------------------------------------------------------

  describe "enable_calendar_feed / rotate_calendar_feed_token" do
    test "enable returns the plain token once and persists only its hash", %{
      workspace: workspace,
      generation: generation
    } do
      assert %{"success" => true, "data" => %{"token" => token}} =
               rpc("enable_calendar_feed", %{"generation" => generation}, ["token"])

      assert is_binary(token) and byte_size(token) >= 40

      hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
      config = File.read!(config_path(workspace))
      assert config =~ hash
      refute config =~ token

      assert %{"success" => true, "data" => %{"feedEnabled" => true}} =
               rpc("calendar_status", %{}, @status_fields)
    end

    test "rotate invalidates the previous token's hash", %{
      workspace: workspace,
      generation: generation
    } do
      assert %{"success" => true, "data" => %{"token" => token1}} =
               rpc("enable_calendar_feed", %{"generation" => generation}, ["token"])

      assert %{"success" => true, "data" => %{"token" => token2}} =
               rpc("rotate_calendar_feed_token", %{"generation" => generation}, ["token"])

      assert token1 != token2

      hash1 = :crypto.hash(:sha256, token1) |> Base.encode16(case: :lower)
      hash2 = :crypto.hash(:sha256, token2) |> Base.encode16(case: :lower)
      config = File.read!(config_path(workspace))
      refute config =~ hash1
      assert config =~ hash2
    end
  end

  # -- cockpit ------------------------------------------------------------------

  describe "cockpit calendar line" do
    test "cockpit_today carries the calendar line for host-zone today", %{workspace: workspace} do
      zone = Valea.Calendar.Engine.host_zone()
      today = DateTime.now!(zone) |> DateTime.to_date()

      write_valea_event!(workspace, "retreat", """
      ---
      title: "Retreat"
      start: #{Date.to_iso8601(today)}
      all_day: true
      ---
      """)

      assert %{"success" => true, "data" => %{"calendar" => calendar}} =
               rpc("cockpit_today", %{}, [
                 %{"calendar" => ["eventsToday", %{"next" => ["time", "title"]}]}
               ])

      assert calendar["eventsToday"] == 1
      # All-day events carry no clock time, so they never become "next".
      assert calendar["next"] == nil
    end

    test "stays lenient: with no workspace open the calendar entry is null" do
      Manager.close()

      assert %{"success" => true, "data" => %{"calendar" => nil}} =
               rpc("cockpit_today", %{}, [
                 %{"calendar" => ["eventsToday", %{"next" => ["time", "title"]}]}
               ])
    end
  end

  # -- generation guards --------------------------------------------------------

  describe "generation guards" do
    test "every mutating action refuses a stale generation", %{generation: generation} do
      stale = generation - 1

      calls = [
        {"setup_calendar_source", %{"source" => "work", "name" => "W", "generation" => stale},
         ["saved"]},
        {"set_calendar_source_url",
         %{"source" => "work", "url" => url("work"), "generation" => stale}, ["accepted"]},
        {"remove_calendar_source", %{"source" => "work", "generation" => stale}, ["removed"]},
        {"purge_calendar_source_files",
         %{"source" => "work", "confirmation" => "work", "generation" => stale}, ["purged"]},
        {"calendar_sync_now", %{"source" => "work", "generation" => stale}, ["started"]},
        {"calendar_doctor", %{"source" => "work", "generation" => stale}, ["ok", "checks"]},
        {"create_valea_event",
         %{
           "name" => "x",
           "title" => "T",
           "start" => "2026-07-21T09:00:00Z",
           "generation" => stale
         }, ["created", "path"]},
        {"update_valea_event",
         %{
           "name" => "x",
           "title" => "T",
           "start" => "2026-07-21T09:00:00Z",
           "generation" => stale
         }, ["updated"]},
        {"delete_valea_event", %{"name" => "x", "confirmation" => "x", "generation" => stale},
         ["deleted"]},
        {"enable_calendar_feed", %{"generation" => stale}, ["token"]},
        {"rotate_calendar_feed_token", %{"generation" => stale}, ["token"]}
      ]

      for {action, input, fields} <- calls do
        assert %{"success" => false, "errors" => errors} = rpc(action, input, fields)
        assert inspect(errors) =~ "workspace_changed", "#{action} did not guard the generation"
      end
    end
  end

  # -- in-lock workspace verification (Codex round 4) ---------------------------

  describe "in-lock workspace verification" do
    # The Codex round-4 posture: a lifecycle RPC parked behind a
    # workspace switch must not mutate the newly current workspace, so
    # every lifecycle mutation re-runs the generation check + root
    # resolution INSIDE the serialized section (`verified_lifecycle/2`)
    # — the out-of-lock pre-check passing before the switch is not
    # enough. Deterministic, no sleeps (the local_test shape): the
    # serializer is held open, the RPC provably parks behind it (its
    # lifecycle call is visible in the serializer's mailbox, which
    # implies its pre-checks already PASSED against the then-current
    # generation), the generation is invalidated in place, then the
    # serializer is released and the parked closure re-verifies.

    test "setup: a parked-then-stale RPC refuses with the config byte-identical and no engine",
         %{workspace: workspace, generation: generation} do
      before = File.read!(config_path(workspace))

      assert_stale_in_lock!(
        "setup_calendar_source",
        %{"source" => "work", "name" => "Work", "generation" => generation},
        ["saved"]
      )

      assert File.read!(config_path(workspace)) == before
      assert status_entry("work") == nil
    end

    test "set-url: a parked-then-stale RPC claims no .source and leaves the engine URL-less",
         %{workspace: workspace, generation: generation} do
      setup_source!(generation, "work")
      await_source!("work")
      before = File.read!(config_path(workspace))

      assert_stale_in_lock!(
        "set_calendar_source_url",
        %{"source" => "work", "url" => url("work"), "generation" => generation},
        ["accepted"]
      )

      refute File.exists?(Path.join([workspace, "sources", "calendar", "work", ".source"]))
      assert status_entry("work")["url_present"] == false
      assert File.read!(config_path(workspace)) == before
    end

    test "remove: a parked-then-stale RPC leaves the entry configured and the engine running",
         %{workspace: workspace, generation: generation} do
      setup_source!(generation, "work")
      await_source!("work")
      before = File.read!(config_path(workspace))

      assert_stale_in_lock!(
        "remove_calendar_source",
        %{"source" => "work", "generation" => generation},
        ["removed"]
      )

      assert File.read!(config_path(workspace)) == before
      assert status_entry("work")["valid"] == true
    end

    test "purge: a parked-then-stale RPC leaves files and index rows intact",
         %{workspace: workspace, generation: generation} do
      setup_source!(generation, "work")
      await_source!("work")
      set_url!("work", generation)

      plant_rows!(workspace, "work", [
        timed_row("t1", "2026-07-20T10:00:00Z", "2026-07-20T11:00:00Z", "Standup")
      ])

      assert %{"success" => true} =
               rpc("remove_calendar_source", %{"source" => "work", "generation" => generation}, [
                 "removed"
               ])

      assert Store.occurrence_count("work") == 1

      assert_stale_in_lock!(
        "purge_calendar_source_files",
        %{"source" => "work", "confirmation" => "work", "generation" => generation},
        ["purged"]
      )

      assert File.dir?(Path.join([workspace, "sources", "calendar", "work"]))
      assert Store.occurrence_count("work") == 1
    end

    test "rotate: a parked-then-stale RPC leaves the stored token hash unchanged",
         %{workspace: workspace, generation: generation} do
      assert %{"success" => true, "data" => %{"token" => token}} =
               rpc("enable_calendar_feed", %{"generation" => generation}, ["token"])

      before = File.read!(config_path(workspace))
      hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
      assert before =~ hash

      assert_stale_in_lock!(
        "rotate_calendar_feed_token",
        %{"generation" => generation},
        ["token"]
      )

      assert File.read!(config_path(workspace)) == before
    end

    test "sync-now: a parked-then-stale RPC starts no pass (no fetch, no snapshot, no rows)",
         %{workspace: workspace, generation: generation} do
      setup_source!(generation, "work")
      await_source!("work")
      set_url!("work", generation)

      assert_stale_in_lock!(
        "calendar_sync_now",
        %{"source" => "work", "generation" => generation},
        ["started"]
      )

      refute File.exists?(Path.join([workspace, "sources", "calendar", "work", "feed.ics"]))
      assert Store.occurrence_count("work") == 0
      refute status_entry("work")["state"] == "syncing"
    end
  end

  # Holds the lifecycle serializer open (the local_test shape): the
  # returned task is parked INSIDE `lifecycle/1` until `send(sup,
  # :release)`, so anything enqueued meanwhile provably runs after.
  defp hold_lifecycle! do
    sup = Process.whereis(Valea.Calendar.Supervisor)
    assert is_pid(sup)
    test_pid = self()

    holder =
      Task.async(fn ->
        Valea.Calendar.Supervisor.lifecycle(fn ->
          send(test_pid, :held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :held
    {sup, holder}
  end

  # Spin (a pure state check — never proceeds early, no sleeps) until a
  # lifecycle call is parked in the serializer's mailbox (the local_test
  # helper): `GenServer.call` enqueues its request message before
  # blocking, so once the call is visible the racing RPC has necessarily
  # passed its out-of-lock pre-checks and parked behind the held
  # serializer.
  defp await_lifecycle_queued(sup, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    {:messages, messages} = Process.info(sup, :messages)

    queued? =
      Enum.any?(messages, fn
        {:"$gen_call", _from, {:lifecycle, _fun}} -> true
        _other -> false
      end)

    cond do
      queued? ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the RPC never queued behind the held lifecycle serializer")

      true ->
        :erlang.yield()
        await_lifecycle_queued(sup, deadline)
    end
  end

  # Simulates the instant a workspace switch completes while the RPC is
  # parked: bumps the Manager's generation counter in place. (A real
  # teardown/reopen would kill the held serializer — and with it the
  # queued call this test is pinning — so the counter bump IS the
  # deterministic seam, exactly what `check_generation/1` keys on.)
  defp invalidate_generation! do
    :sys.replace_state(Manager, fn state -> %{state | generation: state.generation + 1} end)
  end

  # The shared runner: hold the serializer, enqueue `action` so it parks
  # behind it (pre-checks passed), invalidate the generation, release,
  # and assert the parked closure's in-lock re-verification surfaced the
  # typed stale-generation error. Effect-freedom is asserted per-test.
  defp assert_stale_in_lock!(action, input, fields) do
    {sup, holder} = hold_lifecycle!()

    task = Task.async(fn -> rpc(action, input, fields) end)
    await_lifecycle_queued(sup)
    invalidate_generation!()
    send(sup, :release)

    assert :ok = Task.await(holder)
    assert %{"success" => false, "errors" => errors} = Task.await(task)
    assert inspect(errors) =~ "workspace_changed"
  end

  # -- read-only actions without an open workspace ------------------------------

  describe "read-only actions without an open workspace" do
    setup do
      Manager.close()
      :ok
    end

    test "calendar_status surfaces workspace_not_open" do
      assert %{"success" => false, "errors" => errors} =
               rpc("calendar_status", %{}, @status_fields)

      assert inspect(errors) =~ "workspace_not_open"
    end

    test "list_calendar_events surfaces workspace_not_open" do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "list_calendar_events",
                 %{"from" => "2026-07-20", "to" => "2026-07-21", "zone" => "Etc/UTC"},
                 ["events"]
               )

      assert inspect(errors) =~ "workspace_not_open"
    end
  end
end
