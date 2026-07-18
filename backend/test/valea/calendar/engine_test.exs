# A scripted `Valea.Calendar.Fetch` double, injected via the
# `Application.get_env(:valea, :calendar_fetch, ...)` seam (the mail
# `:mail_transport` pattern). `get/3` — the PRODUCTION arity; engines never
# pass the test-only 4th opts arg — pops the next scripted response for its
# URL (the last response is sticky). A `:hang` response announces itself to
# the probe pid and blocks until released, so tests can observe a genuinely
# in-flight pass without sleeping.
defmodule Valea.Calendar.EngineTest.FakeFetch do
  def start_link do
    Agent.start_link(fn -> %{scripts: %{}, probe: nil, calls: []} end, name: __MODULE__)
  end

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  end

  def script(url, responses) when is_list(responses) do
    Agent.update(__MODULE__, fn state -> put_in(state.scripts[url], responses) end)
  end

  def probe(pid), do: Agent.update(__MODULE__, fn state -> %{state | probe: pid} end)

  def calls, do: Agent.get(__MODULE__, & &1.calls)

  def get(url, etag, last_modified) do
    response =
      Agent.get_and_update(__MODULE__, fn state ->
        state = %{state | calls: state.calls ++ [{url, etag, last_modified}]}

        case Map.get(state.scripts, url, []) do
          [] -> {:unchanged, state}
          [last] -> {last, state}
          [head | rest] -> {head, put_in(state.scripts[url], rest)}
        end
      end)

    case response do
      :hang ->
        if probe = Agent.get(__MODULE__, & &1.probe), do: send(probe, {:fetch_called, self()})

        receive do
          {:release, released} -> resolve(released)
        end

      other ->
        resolve(other)
    end
  end

  defp resolve({:body, bytes}), do: {:ok, %{body: bytes, etag: nil, last_modified: nil}}
  defp resolve({:body, bytes, etag, lm}), do: {:ok, %{body: bytes, etag: etag, last_modified: lm}}
  defp resolve(other), do: other
end

defmodule Valea.Calendar.EngineTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias Valea.Calendar.Engine
  alias Valea.Calendar.EngineTest.FakeFetch
  alias Valea.Calendar.Settings
  alias Valea.Calendar.Source
  alias Valea.Calendar.Store
  alias Valea.Calendar.Supervisor, as: CalSupervisor
  alias Valea.Calendar.Views

  @now ~U[2026-07-18 12:00:00Z]
  @zone "Etc/UTC"
  # Default config window: today ± (30, 365) days.
  @from ~D[2026-06-18]
  @to ~D[2027-07-18]

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-cal-engine-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(Path.join(root, "config"))

    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    previous_compiler_options = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous_compiler_options)

    start_supervised!(FakeFetch)
    FakeFetch.probe(self())
    Application.put_env(:valea, :calendar_fetch, FakeFetch)
    on_exit(fn -> Application.delete_env(:valea, :calendar_fetch) end)

    Phoenix.PubSub.subscribe(Valea.PubSub, "calendar")

    on_exit(fn -> File.rm_rf!(dir) end)
    %{root: root}
  end

  # -- fixtures ---------------------------------------------------------------

  defp config(overrides \\ %{}) do
    Map.merge(
      %{name: "Work", past_days: 30, future_days: 365, interval_minutes: 30},
      overrides
    )
  end

  defp start_engine!(root, generation, slug, opts \\ []) do
    cfg =
      %{
        root: root,
        generation: generation,
        source: slug,
        config: Keyword.get(opts, :config, config()),
        now_fun: Keyword.get(opts, :now_fun, fn -> @now end),
        zone_fun: Keyword.get(opts, :zone_fun, fn -> @zone end)
      }
      |> maybe_put(:activate, Keyword.get(opts, :activate))

    start_supervised!({Engine, cfg}, id: :"cal_engine_#{slug}")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp open(root, generation) do
    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, generation}
    )
  end

  defp url(slug), do: "https://feeds.example.com/#{slug}.ics"

  defp source_dir(root, slug), do: Path.join([root, "sources", "calendar", slug])

  defp ics(vevents) do
    (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Valea Test//EN"] ++
       List.flatten(vevents) ++ ["END:VCALENDAR"])
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp vevent(props), do: ["BEGIN:VEVENT"] ++ props ++ ["END:VEVENT"]

  defp timed(uid, date, summary) do
    compact = String.replace(Date.to_iso8601(date), "-", "")

    vevent([
      "UID:#{uid}",
      "DTSTART:#{compact}T100000Z",
      "DTEND:#{compact}T110000Z",
      "SUMMARY:#{summary}"
    ])
  end

  defp feed_two,
    do: ics([timed("a@x", ~D[2026-07-20], "One"), timed("b@x", ~D[2026-07-21], "Two")])

  defp feed_one, do: ics([timed("a@x", ~D[2026-07-20], "One")])
  defp feed_empty, do: ics([])

  defp feed_damaged do
    broken = vevent(["DTSTART:20260720T100000Z", "SUMMARY:No uid"])
    ics([timed("a@x", ~D[2026-07-20], "One"), broken, broken, broken])
  end

  @html "<html><body>Sign in to continue</body></html>"

  defp rev_for(bytes, zone \\ @zone, from \\ @from, to \\ @to) do
    Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) <>
      ":" <> zone <> ":" <> Date.to_iso8601(from) <> ":" <> Date.to_iso8601(to)
  end

  defp row_uids(slug) do
    Store.occurrences_overlapping(
      "0000-01-01T00:00:00Z",
      "9999-12-31T00:00:00Z",
      "0000-01-01",
      "9999-12-31"
    )
    |> Enum.filter(&(&1.source == slug))
    |> Enum.map(& &1.uid)
    |> Enum.sort()
  end

  defp view_files(root, slug) do
    case File.ls(Path.join([source_dir(root, slug), "views", "events"])) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, _} -> :absent
    end
  end

  # Awaits the NEXT pass: skips stale status broadcasts until this pass's
  # "syncing", then returns its first settled status.
  defp await_pass(slug, timeout \\ 3_000) do
    receive do
      {:calendar_status_changed, ^slug, %{state: "syncing"}} -> await_settled(slug, timeout)
      {:calendar_status_changed, ^slug, _stale} -> await_pass(slug, timeout)
    after
      timeout -> flunk("engine #{slug} never started a pass")
    end
  end

  defp await_settled(slug, timeout) do
    receive do
      {:calendar_status_changed, ^slug, %{state: "syncing"}} -> await_settled(slug, timeout)
      {:calendar_status_changed, ^slug, status} -> status
    after
      timeout -> flunk("engine #{slug} never settled")
    end
  end

  defp sync!(slug) do
    assert :ok = Engine.sync_now(slug)
    await_pass(slug)
  end

  # Activates an engine with a URL installed via set_url (the resupply path).
  defp engine_with_url!(root, generation, slug, opts \\ []) do
    pid = start_engine!(root, generation, slug, opts)
    open(root, generation)
    assert :ok = Engine.set_url(slug, url(slug))
    pid
  end

  # -- boot / activation ------------------------------------------------------

  test "boots inert: state inactive, url_present false, sync_now refuses", %{root: root} do
    start_engine!(root, 1, "work")

    assert %{
             source: "work",
             state: "inactive",
             url_present: false,
             event_count: 0,
             unsupported_series: 0,
             last_sync_at: nil,
             last_error: nil,
             notices: []
           } = Engine.status("work")

    assert Engine.sync_now("work") == {:error, :no_url}
  end

  test "a mismatched-generation broadcast is ignored", %{root: root} do
    start_engine!(root, 2, "work")
    open(root, 1)
    assert Engine.status("work").state == "inactive"
  end

  test "unknown slugs: status nil, everything else :not_running" do
    assert Engine.status("ghost") == nil
    assert Engine.sync_now("ghost") == {:error, :not_running}
    assert Engine.set_url("ghost", "https://feeds.example.com/x.ics") == {:error, :not_running}
    assert Engine.with_credentials("ghost", fn _ctx -> :x end) == {:error, :not_running}
  end

  test "activation without a credential: derive still runs, .source untouched, idle url_present false, no poll timer",
       %{root: root} do
    dir = source_dir(root, "work")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "feed.ics"), feed_two())

    start_engine!(root, 3, "work")
    open(root, 3)

    status = Engine.status("work")
    assert status.state == "idle"
    assert status.url_present == false
    assert status.event_count == 2

    # Derived stores were rebuilt from the committed snapshot.
    assert Store.occurrence_count("work") == 2
    assert Store.derived_rev("work") == rev_for(feed_two())
    assert Views.current_rev(dir) == rev_for(feed_two())
    assert length(view_files(root, "work")) == 2

    # No URL: no .source claim, no poll timer.
    refute File.exists?(Path.join(dir, ".source"))
    assert %{poll_timer: nil} = :sys.get_state(GenServer.whereis(Engine.via("work")))
  end

  test "activation with a matching env credential claims .source and arms polling", %{root: root} do
    System.put_env(Settings.env_var("work"), url("work"))
    on_exit(fn -> System.delete_env(Settings.env_var("work")) end)

    dir = source_dir(root, "work")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "feed.ics"), feed_one())

    start_engine!(root, 4, "work")
    open(root, 4)

    status = Engine.status("work")
    assert status.state == "idle"
    assert status.url_present == true
    assert status.event_count == 1

    hash = :crypto.hash(:sha256, url("work")) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    assert File.read!(Path.join(dir, ".source")) == "feeds.example.com\n" <> hash <> "\n"
    assert %{poll_timer: timer} = :sys.get_state(GenServer.whereis(Engine.via("work")))
    assert timer != nil
  end

  test "activation with a mismatching credential: inert identity_mismatch, mirror intact, derive ran",
       %{root: root} do
    dir = source_dir(root, "work")
    :ok = Source.verify_or_claim(dir, "https://other.example.org/else.ics")
    original = File.read!(Path.join(dir, ".source"))
    File.write!(Path.join(dir, "feed.ics"), feed_two())

    System.put_env(Settings.env_var("work"), url("work"))
    on_exit(fn -> System.delete_env(Settings.env_var("work")) end)

    start_engine!(root, 5, "work")
    open(root, 5)

    status = Engine.status("work")
    assert status.state == "identity_mismatch"
    assert status.url_present == false

    # The activation repair attempt ran BEFORE the credential step: the
    # mirror was rebuilt from the committed snapshot and stays intact.
    assert Store.occurrence_count("work") == 2
    assert length(view_files(root, "work")) == 2

    # The mismatched .source was never overwritten; no polling.
    assert File.read!(Path.join(dir, ".source")) == original
    assert %{poll_timer: nil} = :sys.get_state(GenServer.whereis(Engine.via("work")))
    assert Engine.sync_now("work") == {:error, :no_url}
  end

  # -- snapshot-damage activation cases --------------------------------------

  test "activation onto a non-ICS feed.ics leaves both derived stores intact and goes degraded",
       %{root: root} do
    # First: a healthy engine populates the mirror.
    engine_with_url!(root, 6, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")
    assert Store.occurrence_count("work") == 2
    :ok = stop_supervised(:cal_engine_work)

    # Out-of-band damage to the committed snapshot.
    dir = source_dir(root, "work")
    File.write!(Path.join(dir, "feed.ics"), @html)

    start_engine!(root, 7, "work")
    open(root, 7)

    status = Engine.status("work")
    assert status.state == "degraded"
    assert status.last_error =~ "not an ICS"
    assert Store.occurrence_count("work") == 2
    assert length(view_files(root, "work")) == 2
  end

  test "activation onto a partial-damage snapshot over a populated mirror: intact + degraded",
       %{root: root} do
    engine_with_url!(root, 8, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")
    :ok = stop_supervised(:cal_engine_work)

    dir = source_dir(root, "work")
    File.write!(Path.join(dir, "feed.ics"), feed_damaged())

    start_engine!(root, 9, "work")
    open(root, 9)

    status = Engine.status("work")
    assert status.state == "degraded"
    assert status.last_error =~ "malformed"
    assert Store.occurrence_count("work") == 2
    assert length(view_files(root, "work")) == 2
  end

  test "activation onto a legitimately-empty valid snapshot over an empty mirror: clean rebuild",
       %{root: root} do
    dir = source_dir(root, "work")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "feed.ics"), feed_empty())

    start_engine!(root, 10, "work")
    open(root, 10)

    status = Engine.status("work")
    assert status.state == "idle"
    assert status.event_count == 0
    assert Store.derived_rev("work") == rev_for(feed_empty())
    assert Views.current_rev(dir) == rev_for(feed_empty())
    assert view_files(root, "work") == []
  end

  test "damaged snapshot then 304: activation preserves both stores; the 304 repair attempt rejects again",
       %{root: root} do
    System.put_env(Settings.env_var("work"), url("work"))
    on_exit(fn -> System.delete_env(Settings.env_var("work")) end)

    engine_with_url!(root, 11, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")
    good_rev = Store.derived_rev("work")
    :ok = stop_supervised(:cal_engine_work)

    dir = source_dir(root, "work")
    File.write!(Path.join(dir, "feed.ics"), @html)

    # Restart WITH a credential onto the damaged snapshot.
    start_engine!(root, 12, "work")
    open(root, 12)
    assert %{state: "degraded"} = Engine.status("work")
    assert Store.occurrence_count("work") == 2

    # The next poll answers 304: the marker check sees the mismatch, the
    # repair attempt runs, and the SAME guard rejects again.
    FakeFetch.script(url("work"), [:unchanged])
    status = sync!("work")
    assert status.state == "degraded"
    assert status.last_error =~ "not an ICS"
    assert Store.occurrence_count("work") == 2
    assert Store.derived_rev("work") == good_rev
    assert length(view_files(root, "work")) == 2
  end

  # -- passes: replace-mirror / degraded / guards ------------------------------

  test "replace-mirror: a shrunken feed removes rows and views", %{root: root} do
    engine_with_url!(root, 20, "work")

    FakeFetch.script(url("work"), [{:body, feed_two()}])
    status = sync!("work")
    assert status.state == "idle"
    assert status.event_count == 2
    assert_receive {:calendar_synced, "work", %{event_count: 2}}
    assert row_uids("work") == ["a@x", "b@x"]
    assert length(view_files(root, "work")) == 2

    FakeFetch.script(url("work"), [{:body, feed_one()}])
    status = sync!("work")
    assert status.state == "idle"
    assert status.event_count == 1
    assert row_uids("work") == ["a@x"]
    assert length(view_files(root, "work")) == 1
    assert Store.derived_rev("work") == rev_for(feed_one())
  end

  test "degraded-keeps-mirror: a fetch failure leaves snapshot, views, and rows fully intact",
       %{root: root} do
    engine_with_url!(root, 21, "work")

    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")

    FakeFetch.script(url("work"), [{:error, :timeout}])
    status = sync!("work")
    assert status.state == "degraded"
    assert status.last_error =~ "timeout"
    assert Store.occurrence_count("work") == 2
    assert File.read!(Path.join(source_dir(root, "work"), "feed.ics")) == feed_two()
    assert length(view_files(root, "work")) == 2
    assert Store.sync_meta("work").last_error =~ "timeout"

    # The next good tick recovers.
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle", last_error: nil} = sync!("work")
  end

  test "zero-parseable guard: an empty-but-valid response never replaces a populated mirror and is never committed",
       %{root: root} do
    engine_with_url!(root, 22, "work")

    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")

    FakeFetch.script(url("work"), [{:body, feed_empty()}])
    status = sync!("work")
    assert status.state == "degraded"
    assert status.last_error =~ "zero parseable"

    # Admission ran BEFORE the swap: the committed snapshot is still the old
    # feed, and both derived stores are untouched.
    assert File.read!(Path.join(source_dir(root, "work"), "feed.ics")) == feed_two()
    assert Store.occurrence_count("work") == 2
    assert Store.derived_rev("work") == rev_for(feed_two())
    assert length(view_files(root, "work")) == 2
  end

  test "an HTML error page served as 200 is rejected and never committed", %{root: root} do
    engine_with_url!(root, 23, "work")

    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")

    FakeFetch.script(url("work"), [{:body, @html}])
    status = sync!("work")
    assert status.state == "degraded"
    assert status.last_error =~ "not an ICS"
    assert File.read!(Path.join(source_dir(root, "work"), "feed.ics")) == feed_two()
    assert Store.occurrence_count("work") == 2
  end

  test "partial-damage guard: a populated mirror survives 1 valid + 3 malformed; a shrunken all-parseable feed replaces",
       %{root: root} do
    engine_with_url!(root, 24, "work")

    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")

    FakeFetch.script(url("work"), [{:body, feed_damaged()}])
    status = sync!("work")
    assert status.state == "degraded"
    assert status.last_error =~ "malformed"
    assert row_uids("work") == ["a@x", "b@x"]
    assert File.read!(Path.join(source_dir(root, "work"), "feed.ics")) == feed_two()

    # A legitimately shrunken feed — fewer events, all parseable — replaces.
    FakeFetch.script(url("work"), [{:body, feed_one()}])
    assert %{state: "idle"} = sync!("work")
    assert row_uids("work") == ["a@x"]
  end

  test "supported → unsupported transition: occurrences drop, unsupported_series increments",
       %{root: root} do
    engine_with_url!(root, 25, "work")

    supported =
      ics([
        vevent([
          "UID:s@x",
          "DTSTART:20260706T090000Z",
          "DTEND:20260706T093000Z",
          "SUMMARY:Series",
          "RRULE:FREQ=DAILY;COUNT=3"
        ])
      ])

    unsupported =
      ics([
        vevent([
          "UID:s@x",
          "DTSTART:20260706T090000Z",
          "DTEND:20260706T093000Z",
          "SUMMARY:Series",
          "RRULE:FREQ=YEARLY;BYWEEKNO=2"
        ])
      ])

    FakeFetch.script(url("work"), [{:body, supported}])
    status = sync!("work")
    assert status.state == "idle"
    assert status.event_count == 3
    assert status.unsupported_series == 0

    FakeFetch.script(url("work"), [{:body, unsupported}])
    status = sync!("work")
    assert status.state == "idle"
    assert status.event_count == 0
    assert status.unsupported_series == 1
    assert Enum.any?(status.notices, &(&1 =~ "s@x"))

    [view] = view_files(root, "work")

    assert File.read!(Path.join([source_dir(root, "work"), "views", "events", view])) =~
             "recurrence_unsupported: true"
  end

  # -- single-flight / isolation ----------------------------------------------

  test "single-flight: a second sync_now while a pass runs is :busy; status shows syncing",
       %{root: root} do
    engine_with_url!(root, 30, "work")

    FakeFetch.script(url("work"), [:hang])
    assert :ok = Engine.sync_now("work")
    assert_receive {:fetch_called, task_pid}
    assert Engine.status("work").state == "syncing"

    assert Engine.sync_now("work") == {:error, :busy}
    assert Engine.with_credentials("work", fn _ctx -> :x end) == {:error, :busy}

    send(task_pid, {:release, :unchanged})
    assert %{state: "idle"} = await_pass("work")
  end

  test "a pass task killed mid-flight degrades and recovers, never stuck syncing", %{root: root} do
    engine_with_url!(root, 31, "work")

    FakeFetch.script(url("work"), [:hang])
    assert :ok = Engine.sync_now("work")
    assert_receive {:fetch_called, task_pid}

    Process.exit(task_pid, :kill)
    status = await_pass("work")
    assert status.state == "degraded"
    assert %{sync_task: nil} = :sys.get_state(GenServer.whereis(Engine.via("work")))

    FakeFetch.script(url("work"), [{:body, feed_one()}])
    assert %{state: "idle"} = sync!("work")
  end

  test "per-source isolation: one broken feed degrades one source", %{root: root} do
    engine_with_url!(root, 32, "work")
    engine_with_url!(root, 32, "personal")

    FakeFetch.script(url("work"), [{:error, :tls}])
    FakeFetch.script(url("personal"), [{:body, feed_two()}])

    assert %{state: "degraded"} = sync!("work")
    assert %{state: "idle", event_count: 2} = sync!("personal")

    assert Engine.status("work").state == "degraded"
    assert Engine.status("personal").state == "idle"
    assert Store.occurrence_count("work") == 0
    assert Store.occurrence_count("personal") == 2

    all = Engine.statuses()
    assert Map.keys(all) |> Enum.sort() == ["personal", "work"]
  end

  # -- self-heal / marker repair ----------------------------------------------

  test "crash between the feed.ics swap and the derive: the next activation converges", %{
    root: root
  } do
    engine_with_url!(root, 40, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")
    :ok = stop_supervised(:cal_engine_work)

    # Simulate the crash window: the snapshot was committed but neither
    # derived store was rebuilt from it.
    File.write!(Path.join(source_dir(root, "work"), "feed.ics"), feed_one())

    start_engine!(root, 41, "work")
    open(root, 41)

    assert Engine.status("work").state == "idle"
    assert row_uids("work") == ["a@x"]
    assert Store.derived_rev("work") == rev_for(feed_one())
    assert Views.current_rev(source_dir(root, "work")) == rev_for(feed_one())
  end

  test "unconditional activation repair: a deleted view file is restored even when both markers match",
       %{root: root} do
    engine_with_url!(root, 42, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")
    :ok = stop_supervised(:cal_engine_work)

    # Out-of-band damage that leaves BOTH markers current.
    dir = source_dir(root, "work")
    [view | _] = view_files(root, "work")
    File.rm!(Path.join([dir, "views", "events", view]))
    assert Views.current_rev(dir) == rev_for(feed_two())
    assert Store.derived_rev("work") == rev_for(feed_two())

    start_engine!(root, 43, "work")
    open(root, 43)

    assert Engine.status("work").state == "idle"
    assert length(view_files(root, "work")) == 2

    # A subsequent 304 pass keeps them intact.
    assert :ok = Engine.set_url("work", url("work"))
    FakeFetch.script(url("work"), [:unchanged])
    assert %{state: "idle"} = sync!("work")
    assert length(view_files(root, "work")) == 2
    assert Store.occurrence_count("work") == 2
  end

  test "unconditional activation repair: an index row removed out-of-band is restored", %{
    root: root
  } do
    engine_with_url!(root, 44, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")
    :ok = stop_supervised(:cal_engine_work)

    # Remove one row directly; the sync-state marker still matches.
    Valea.Calendar.Store.Occurrence
    |> Ash.Query.filter(source == "work" and uid == "a@x")
    |> Ash.bulk_destroy!(:destroy, %{})

    assert Store.occurrence_count("work") == 1
    assert Store.derived_rev("work") == rev_for(feed_two())

    start_engine!(root, 45, "work")
    open(root, 45)

    assert Engine.status("work").state == "idle"
    assert row_uids("work") == ["a@x", "b@x"]
  end

  test "stale-derive repair THROUGH a 304: a destroyed views tree is rebuilt on an unchanged pass",
       %{root: root} do
    engine_with_url!(root, 46, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")

    # A failed/incomplete derive left the views tree gone while the feed
    # keeps answering 304.
    File.rm_rf!(Path.join(source_dir(root, "work"), "views"))
    assert Views.current_rev(source_dir(root, "work")) == nil

    FakeFetch.script(url("work"), [:unchanged])
    assert %{state: "idle"} = sync!("work")

    assert Views.current_rev(source_dir(root, "work")) == rev_for(feed_two())
    assert length(view_files(root, "work")) == 2
    assert Store.occurrence_count("work") == 2
  end

  test "two-store check: a stale SQLite marker behind current views re-derives on a 304", %{
    root: root
  } do
    engine_with_url!(root, 47, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")

    # Simulate a crash between the views swap and the SQLite commit: views
    # carry the current rev, the index a stale one with stale rows.
    Store.replace_source!("work", [], "stale-rev", nil, nil)
    assert Store.occurrence_count("work") == 0
    assert Views.current_rev(source_dir(root, "work")) == rev_for(feed_two())

    FakeFetch.script(url("work"), [:unchanged])
    assert %{state: "idle"} = sync!("work")
    assert Store.derived_rev("work") == rev_for(feed_two())
    assert Store.occurrence_count("work") == 2
  end

  test "two-store check (inverse): a stale views marker behind a current index re-derives on a 304",
       %{root: root} do
    engine_with_url!(root, 48, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")

    File.write!(Path.join([source_dir(root, "work"), "views", ".rev"]), "stale-rev")

    FakeFetch.script(url("work"), [:unchanged])
    assert %{state: "idle"} = sync!("work")
    assert Views.current_rev(source_dir(root, "work")) == rev_for(feed_two())
    assert Store.derived_rev("work") == rev_for(feed_two())
  end

  test "host-zone change re-derives through 304s", %{root: root} do
    {:ok, zone_agent} = Agent.start_link(fn -> "Etc/UTC" end)

    start_engine!(root, 49, "work", zone_fun: fn -> Agent.get(zone_agent, & &1) end)
    open(root, 49)
    assert :ok = Engine.set_url("work", url("work"))

    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")
    assert Store.derived_rev("work") =~ ":Etc/UTC:"

    Agent.update(zone_agent, fn _ -> "America/New_York" end)
    FakeFetch.script(url("work"), [:unchanged])
    assert %{state: "idle"} = sync!("work")

    assert Store.derived_rev("work") =~ ":America/New_York:"
    assert Views.current_rev(source_dir(root, "work")) == Store.derived_rev("work")
    assert Store.occurrence_count("work") == 2
  end

  test "rolling-window re-derive: advancing the clock under continuing 304s rolls occurrences in and out",
       %{root: root} do
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-07-18 12:00:00Z] end)

    start_engine!(root, 50, "work",
      config: config(%{past_days: 1, future_days: 2}),
      now_fun: fn -> Agent.get(clock, & &1) end
    )

    open(root, 50)
    assert :ok = Engine.set_url("work", url("work"))

    body = ics([timed("near@x", ~D[2026-07-19], "Near"), timed("far@x", ~D[2026-07-23], "Far")])
    FakeFetch.script(url("work"), [{:body, body}])
    assert %{state: "idle"} = sync!("work")
    assert row_uids("work") == ["near@x"]
    assert Store.derived_rev("work") == rev_for(body, @zone, ~D[2026-07-17], ~D[2026-07-20])

    # Day rollover past the future boundary; the feed keeps answering 304.
    Agent.update(clock, fn _ -> ~U[2026-07-22 12:00:00Z] end)
    FakeFetch.script(url("work"), [:unchanged])
    assert %{state: "idle"} = sync!("work")

    assert row_uids("work") == ["far@x"]
    assert Store.derived_rev("work") == rev_for(body, @zone, ~D[2026-07-21], ~D[2026-07-24])
  end

  test "window-config change re-derives at the next activation", %{root: root} do
    engine_with_url!(root, 51, "work", config: config(%{past_days: 1, future_days: 2}))

    body = ics([timed("near@x", ~D[2026-07-19], "Near"), timed("far@x", ~D[2026-07-23], "Far")])
    FakeFetch.script(url("work"), [{:body, body}])
    assert %{state: "idle"} = sync!("work")
    assert row_uids("work") == ["near@x"]

    # The config change lands via a rehash restart — same effect here.
    :ok = stop_supervised(:cal_engine_work)
    start_engine!(root, 52, "work", config: config(%{past_days: 1, future_days: 10}))
    open(root, 52)

    assert Engine.status("work").state == "idle"
    assert row_uids("work") == ["far@x", "near@x"]
    assert Store.derived_rev("work") == rev_for(body, @zone, ~D[2026-07-17], ~D[2026-07-28])
  end

  # -- set_url admission / with_credentials -----------------------------------

  test "set_url rejects a non-HTTPS URL before anything is stored or claimed", %{root: root} do
    start_engine!(root, 60, "work")
    open(root, 60)

    assert Engine.set_url("work", "http://feeds.example.com/work.ics") == {:error, :not_https}
    assert Engine.set_url("work", "not a url at all") == {:error, :invalid_url}

    refute File.exists?(Path.join(source_dir(root, "work"), ".source"))
    assert Engine.status("work").url_present == false
    assert Engine.sync_now("work") == {:error, :no_url}

    # A valid URL is then accepted and claims .source.
    assert :ok = Engine.set_url("work", url("work"))
    assert File.exists?(Path.join(source_dir(root, "work"), ".source"))
    assert Engine.status("work").url_present == true
  end

  test "set_url against a mismatching .source refuses and stores no closure", %{root: root} do
    dir = source_dir(root, "work")
    :ok = Source.verify_or_claim(dir, "https://other.example.org/else.ics")

    start_engine!(root, 61, "work")
    open(root, 61)

    assert Engine.set_url("work", url("work")) == {:error, :identity_mismatch}
    assert Engine.status("work").url_present == false
    assert Engine.status("work").state == "identity_mismatch"
    assert Engine.sync_now("work") == {:error, :no_url}
  end

  test "with_credentials runs the fun in the engine process with the closure ctx; no URL in the result or state dump",
       %{root: root} do
    start_engine!(root, 62, "work")
    open(root, 62)

    assert Engine.with_credentials("work", fn _ctx -> :x end) == {:error, :no_url}

    assert :ok = Engine.set_url("work", url("work"))

    engine_pid = GenServer.whereis(Engine.via("work"))

    assert {:ok, result} =
             Engine.with_credentials("work", fn ctx ->
               %{
                 ran_in: self(),
                 url_fun?: is_function(ctx.url_fun, 0),
                 etag: ctx.etag,
                 last_modified: ctx.last_modified,
                 interval_minutes: ctx.interval_minutes,
                 last_sync_at: ctx.last_sync_at
               }
             end)

    # The fun ran INSIDE the engine process; the closure never crossed a
    # process boundary and the URL never appears in the result.
    assert result.ran_in == engine_pid
    assert result.url_fun? == true
    assert result.interval_minutes == 30
    refute inspect(result, limit: :infinity, printable_limit: :infinity) =~ url("work")

    dump =
      engine_pid |> :sys.get_state() |> inspect(limit: :infinity, printable_limit: :infinity)

    refute dump =~ url("work")
  end

  # -- supervisor: children, rehash, lifecycle, purge ---------------------------

  test "supervisor boots one engine per valid source and rehash tracks config changes", %{
    root: root
  } do
    :ok = Settings.put_source(root, "work", "Work")

    start_supervised!({CalSupervisor, %{root: root, generation: 70}})
    open(root, 70)

    assert Engine.status("work") != nil
    assert Engine.status("personal") == nil

    # A newly-added source gets a self-activating engine on rehash.
    :ok = Settings.put_source(root, "personal", "Personal")
    assert :ok = CalSupervisor.rehash()

    assert Engine.status("personal") != nil
    assert Engine.status("personal").state == "idle"

    # A removed source's engine is stopped.
    :ok = Settings.remove_source(root, "personal")
    assert :ok = CalSupervisor.rehash()
    assert Engine.status("personal") == nil
    assert Engine.status("work") != nil
  end

  test "lifecycle/1 serializes through the supervisor process and is re-entrant", %{root: root} do
    start_supervised!({CalSupervisor, %{root: root, generation: 71}})

    sup_pid = Process.whereis(CalSupervisor)
    assert {:ran_in, sup_pid} == CalSupervisor.lifecycle(fn -> {:ran_in, self()} end)

    # Re-entrant: a lifecycle fun may call rehash/purge without deadlocking.
    assert :ok = CalSupervisor.lifecycle(fn -> CalSupervisor.rehash() end)
  end

  test "purge! refuses while the source is still configured", %{root: root} do
    :ok = Settings.put_source(root, "work", "Work")
    start_supervised!({CalSupervisor, %{root: root, generation: 72}})

    assert CalSupervisor.purge!("work") == {:error, :still_configured}
  end

  test "purge! rejects the reserved and invalid slugs", %{root: root} do
    start_supervised!({CalSupervisor, %{root: root, generation: 73}})

    assert CalSupervisor.purge!("valea") == {:error, :invalid_slug}
    assert CalSupervisor.purge!("../evil") == {:error, :invalid_slug}
    assert CalSupervisor.purge!("UPPER") == {:error, :invalid_slug}
  end

  test "purge-vs-degraded serialization: remove stops the engine, the in-flight pass is awaited, purge leaves nothing to resurrect",
       %{root: root} do
    System.put_env(Settings.env_var("work"), url("work"))
    on_exit(fn -> System.delete_env(Settings.env_var("work")) end)

    :ok = Settings.put_source(root, "work", "Work")
    start_supervised!({CalSupervisor, %{root: root, generation: 74}})
    open(root, 74)

    # Populate the mirror, then hang the next pass mid-fetch.
    FakeFetch.script(url("work"), [{:body, feed_two()}, :hang])
    assert %{state: "idle"} = sync!("work")
    assert Store.occurrence_count("work") == 2

    assert :ok = Engine.sync_now("work")
    assert_receive {:fetch_called, task_pid}
    task_ref = Process.monitor(task_pid)

    # Remove + rehash: the engine (and its linked in-flight pass task) is
    # awaited/terminated before rehash returns.
    :ok = Settings.remove_source(root, "work")
    assert :ok = CalSupervisor.rehash()
    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 2_000
    assert Engine.status("work") == nil

    assert :ok = CalSupervisor.purge!("work")

    refute File.exists?(source_dir(root, "work"))
    assert Store.occurrence_count("work") == 0
    assert Store.sync_meta("work") == nil

    # No resurrection: nothing recreates the tree or the rows.
    assert Engine.status("work") == nil
    refute File.exists?(source_dir(root, "work"))
  end

  test "purge! is idempotent for an unconfigured slug with no files", %{root: root} do
    start_supervised!({CalSupervisor, %{root: root, generation: 75}})
    assert :ok = CalSupervisor.purge!("ghost")
  end
end
