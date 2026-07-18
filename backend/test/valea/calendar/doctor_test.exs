# A scripted `Valea.Calendar.Fetch` double (get/3 — the PRODUCTION arity;
# neither the engine nor the doctor ever passes the test-only 4th opts
# arg), injected via the `Application.get_env(:valea, :calendar_fetch, ...)`
# seam so the engine's own passes and the Doctor's probe share one script
# store. The last response for a URL is sticky; `:hang` announces itself to
# the probe pid and blocks until released; `:raise_with_url` raises with
# the URL embedded in the message — the doctor's scrub must keep it out of
# every check detail.
defmodule Valea.Calendar.DoctorTest.FakeFetch do
  def start_link do
    Agent.start_link(fn -> %{scripts: %{}, probe: nil} end, name: __MODULE__)
  end

  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def script(url, responses) when is_list(responses) do
    Agent.update(__MODULE__, fn state -> put_in(state.scripts[url], responses) end)
  end

  def probe(pid), do: Agent.update(__MODULE__, fn state -> %{state | probe: pid} end)

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
      :hang ->
        if probe = Agent.get(__MODULE__, & &1.probe), do: send(probe, {:fetch_called, self()})

        receive do
          {:release, released} -> resolve(released, url)
        end

      other ->
        resolve(other, url)
    end
  end

  defp resolve({:body, bytes}, _url), do: {:ok, %{body: bytes, etag: nil, last_modified: nil}}
  defp resolve(:raise_with_url, url), do: raise("fetch exploded for " <> url)
  defp resolve(other, _url), do: other
end

defmodule Valea.Calendar.DoctorTest do
  use ExUnit.Case, async: false

  alias Valea.Calendar.Doctor
  alias Valea.Calendar.DoctorTest.FakeFetch
  alias Valea.Calendar.Engine
  alias Valea.Calendar.Settings

  @now ~U[2026-07-18 12:00:00Z]
  @zone "Etc/UTC"
  @check_ids [
    "config_present",
    "url_present",
    "reachable",
    "parse_ok",
    "freshness",
    "feed_endpoint"
  ]

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-cal-doctor-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
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

  defp config do
    %{name: "Work", past_days: 30, future_days: 365, interval_minutes: 30}
  end

  defp start_engine!(root, generation, slug) do
    cfg = %{
      root: root,
      generation: generation,
      source: slug,
      config: config(),
      now_fun: fn -> @now end,
      zone_fun: fn -> @zone end
    }

    start_supervised!({Engine, cfg}, id: :"cal_engine_#{slug}")
  end

  defp open(root, generation) do
    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, generation}
    )
  end

  defp url(slug), do: "https://feeds.example.com/#{slug}.ics"

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

  # A configured, running engine with a URL installed (the resupply path).
  defp ready_engine!(root, generation, slug) do
    :ok = Settings.put_source(root, slug, "Work")
    start_engine!(root, generation, slug)
    open(root, generation)
    assert :ok = Engine.set_url(slug, url(slug))
  end

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

  defp ctx(root, overrides \\ %{}) do
    Map.merge(%{root: root, source: "work", feed_probe: fn -> :ok end}, overrides)
  end

  defp check(checks, id), do: Enum.find(checks, &(&1["id"] == id))

  defp dump(checks), do: inspect(checks, limit: :infinity, printable_limit: :infinity)

  # -- gating -----------------------------------------------------------------

  test "unconfigured source: config_present fails, the gated chain is unknown, feed_endpoint still runs",
       %{root: root} do
    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(ctx(root))

    assert Enum.map(checks, & &1["id"]) == @check_ids

    assert %{"status" => "failed", "remedy" => remedy} = check(checks, "config_present")
    assert is_binary(remedy)

    for id <- ["url_present", "reachable", "parse_ok", "freshness"] do
      assert check(checks, id)["status"] == "unknown", "#{id} should be gated unknown"
    end

    # feed_endpoint is independent of the per-source chain: no token
    # configured -> failed with the enable remedy.
    assert %{"status" => "failed", "remedy" => feed_remedy} = check(checks, "feed_endpoint")
    assert is_binary(feed_remedy)
  end

  test "configured source with NO running engine: url_present fails with the resupply remedy",
       %{root: root} do
    :ok = Settings.put_source(root, "work", "Work")

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(ctx(root))

    assert check(checks, "config_present")["status"] == "ok"
    assert %{"status" => "failed", "remedy" => remedy} = check(checks, "url_present")
    assert is_binary(remedy)

    for id <- ["reachable", "parse_ok", "freshness"] do
      assert check(checks, id)["status"] == "unknown"
    end
  end

  test "running engine without a URL: url_present fails, network checks unknown", %{root: root} do
    :ok = Settings.put_source(root, "work", "Work")
    start_engine!(root, 1, "work")
    open(root, 1)

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(ctx(root))

    assert check(checks, "config_present")["status"] == "ok"
    assert check(checks, "url_present")["status"] == "failed"
    assert check(checks, "reachable")["status"] == "unknown"
  end

  test "an invalid per-source config entry fails config_present with the entry's reason", %{
    root: root
  } do
    File.write!(
      Path.join(root, "config/calendar.yaml"),
      "version: 1\nsources:\n  work:\n    name: 7\n"
    )

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(ctx(root))

    assert %{"status" => "failed", "detail" => detail} = check(checks, "config_present")
    assert detail =~ "name"
  end

  # -- the full pipeline ------------------------------------------------------

  test "full pipeline ok after a successful pass — and NO URL host or token anywhere in the output",
       %{root: root} do
    ready_engine!(root, 2, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")

    {:ok, token} = Settings.generate_feed_token(root)

    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert {:ok, %{checks: checks, ok: true}} = Doctor.run(ctx(root))

    for id <- @check_ids do
      assert check(checks, id)["status"] == "ok", "#{id} should be ok"
    end

    assert check(checks, "parse_ok")["detail"] =~ "2"

    # THE no-secret pin: the fixture URL's host and the feed token never
    # appear anywhere in the full doctor output.
    output = dump(checks)
    refute output =~ url("work")
    refute output =~ "feeds.example.com"
    refute output =~ token
  end

  test "a 304 probe reports reachable and parses the committed snapshot", %{root: root} do
    ready_engine!(root, 3, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")

    FakeFetch.script(url("work"), [:unchanged])
    assert {:ok, %{checks: checks}} = Doctor.run(ctx(root))

    assert %{"status" => "ok", "detail" => detail} = check(checks, "reachable")
    assert detail =~ "304"
    assert %{"status" => "ok"} = check(checks, "parse_ok")
    assert check(checks, "parse_ok")["detail"] =~ "2"
  end

  # -- reachable failures -----------------------------------------------------

  test "an HTTP failure fails reachable with the status, gates parse/freshness, echoes no host",
       %{root: root} do
    ready_engine!(root, 4, "work")
    FakeFetch.script(url("work"), [{:error, {:http, 403}}])

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(ctx(root))

    assert %{"status" => "failed", "detail" => detail, "remedy" => remedy} =
             check(checks, "reachable")

    assert detail =~ "403"
    assert is_binary(remedy)
    assert check(checks, "parse_ok")["status"] == "unknown"
    assert check(checks, "freshness")["status"] == "unknown"

    refute dump(checks) =~ "feeds.example.com"
  end

  test "a TLS failure fails reachable with a TLS detail", %{root: root} do
    ready_engine!(root, 5, "work")
    FakeFetch.script(url("work"), [{:error, :tls}])

    assert {:ok, %{checks: checks}} = Doctor.run(ctx(root))
    assert %{"status" => "failed", "detail" => detail} = check(checks, "reachable")
    assert detail =~ "TLS"
  end

  test "a crashing fetch is rescued and the URL + host are scrubbed from the detail", %{
    root: root
  } do
    ready_engine!(root, 6, "work")
    FakeFetch.script(url("work"), [:raise_with_url])

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(ctx(root))

    assert %{"status" => "failed", "detail" => detail} = check(checks, "reachable")
    assert detail =~ "fetch exploded"
    refute detail =~ url("work")
    refute detail =~ "feeds.example.com"
  end

  test "a busy engine (in-flight pass) fails reachable with the try-again remedy", %{root: root} do
    ready_engine!(root, 7, "work")
    FakeFetch.script(url("work"), [:hang])
    assert :ok = Engine.sync_now("work")
    assert_receive {:fetch_called, task_pid}

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(ctx(root))
    assert %{"status" => "failed", "detail" => detail} = check(checks, "reachable")
    assert detail =~ "busy"
    assert check(checks, "parse_ok")["status"] == "unknown"

    send(task_pid, {:release, :unchanged})
    await_pass("work")
  end

  # -- parse_ok ---------------------------------------------------------------

  test "a non-ICS response: reachable ok, parse_ok failed, freshness gated unknown", %{root: root} do
    ready_engine!(root, 8, "work")
    FakeFetch.script(url("work"), [{:body, "<html><body>Sign in</body></html>"}])

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(ctx(root))

    assert check(checks, "reachable")["status"] == "ok"
    assert %{"status" => "failed", "detail" => detail} = check(checks, "parse_ok")
    assert detail =~ "ICS"
    assert check(checks, "freshness")["status"] == "unknown"
  end

  # -- freshness --------------------------------------------------------------

  test "a source that never completed a sync fails freshness", %{root: root} do
    ready_engine!(root, 9, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(ctx(root))

    assert check(checks, "reachable")["status"] == "ok"
    assert check(checks, "parse_ok")["status"] == "ok"
    assert %{"status" => "failed", "remedy" => remedy} = check(checks, "freshness")
    assert is_binary(remedy)
  end

  test "a last sync older than twice the interval fails freshness (wedged poller)", %{root: root} do
    ready_engine!(root, 10, "work")
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert %{state: "idle"} = sync!("work")

    FakeFetch.script(url("work"), [{:body, feed_two()}])

    three_hours_on = fn -> DateTime.add(DateTime.utc_now(), 3 * 3600, :second) end

    assert {:ok, %{checks: checks, ok: false}} =
             Doctor.run(ctx(root, %{now_fun: three_hours_on}))

    assert %{"status" => "failed", "detail" => detail} = check(checks, "freshness")
    assert detail =~ "minute"

    # And with the real clock the same source is fresh.
    FakeFetch.script(url("work"), [{:body, feed_two()}])
    assert {:ok, %{checks: fresh_checks}} = Doctor.run(ctx(root))
    assert check(fresh_checks, "freshness")["status"] == "ok"
  end

  # -- feed_endpoint ----------------------------------------------------------

  test "feed_endpoint: no token configured fails with the enable remedy", %{root: root} do
    assert {:ok, %{checks: checks}} = Doctor.run(ctx(root))

    assert %{"status" => "failed", "detail" => detail, "remedy" => remedy} =
             check(checks, "feed_endpoint")

    assert detail =~ "not enabled"
    assert is_binary(remedy)
  end

  test "feed_endpoint: token configured + answering probe is ok; a dead probe fails", %{
    root: root
  } do
    {:ok, _token} = Settings.generate_feed_token(root)

    assert {:ok, %{checks: checks}} = Doctor.run(ctx(root, %{feed_probe: fn -> :ok end}))
    assert check(checks, "feed_endpoint")["status"] == "ok"

    assert {:ok, %{checks: dead}} =
             Doctor.run(ctx(root, %{feed_probe: fn -> {:error, :unreachable} end}))

    assert %{"status" => "failed", "detail" => detail} = check(dead, "feed_endpoint")
    assert detail =~ "did not answer"
  end

  # -- remedies ---------------------------------------------------------------

  test "every failed check carries a copyable remedy", %{root: root} do
    # An unconfigured source + no token fails several checks at once.
    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(ctx(root))

    for %{"status" => "failed"} = failed_check <- checks do
      assert is_binary(failed_check["remedy"]) and failed_check["remedy"] != "",
             "#{failed_check["id"]} is failed but carries no remedy"
    end
  end
end
