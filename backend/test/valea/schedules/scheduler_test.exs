defmodule Valea.Schedules.SchedulerTest do
  # async: false — `Valea.Schedules.Scheduler`, `Valea.Ledger.Writer`,
  # `Valea.Audit` and `Valea.Repo` all register under their module names.
  use ExUnit.Case, async: false

  alias Valea.Schedules.Entry
  alias Valea.Schedules.Scheduler
  alias Valea.Schedules.Store

  @icm_id "9f1c0e8a-0000-4000-8000-000000000001"
  @generation 7

  # The determinism harness: a runner that records what it was asked to launch
  # instead of launching it. Liveness is a runner concern precisely so the
  # scheduler never needs to inspect process state.
  #
  # It answers `live?/4` the way `Runner.Live` does, and that is deliberate. An
  # earlier version keyed liveness off `{icm_id, schedule_id}` and ignored
  # `last_run` entirely — which masked a real bug: the scheduler was handing it
  # the newest run row, and a `skipped: still running` record is NEWER than the
  # run it describes, so from the second skip onwards production read "not live"
  # and launched a second concurrent session. A fake that ignores the argument
  # under test cannot fail the test that matters. So: a prompt run is live iff
  # `last_run` is a running-shaped row whose SESSION the test still holds open,
  # and a launched session is registered as live automatically (a started
  # session is live until something ends it).
  defmodule FakeRunner do
    @moduledoc false
    @behaviour Valea.Schedules.Runner

    @agent __MODULE__.State

    def child_spec(test), do: %{id: @agent, start: {__MODULE__, :start_link, [test]}}

    def start_link(test) do
      Agent.start_link(
        fn ->
          %{test: test, sessions: MapSet.new(), commands: MapSet.new(), fail: nil, seq: 0}
        end,
        name: @agent
      )
    end

    @doc "Ends a live prompt session, as an agent finishing its turn would."
    def end_session(session_id) do
      Agent.update(@agent, &%{&1 | sessions: MapSet.delete(&1.sessions, session_id)})
    end

    @doc "Marks a session live without a launch — for a pre-seeded run row."
    def mark_session_live(session_id) do
      Agent.update(@agent, &%{&1 | sessions: MapSet.put(&1.sessions, session_id)})
    end

    @doc "Ends a live command run (the `CommandRun` process going away)."
    def end_command(icm_id, schedule_id) do
      Agent.update(@agent, &%{&1 | commands: MapSet.delete(&1.commands, {icm_id, schedule_id})})
    end

    def fail(reason), do: Agent.update(@agent, fn s -> %{s | fail: reason} end)

    @impl true
    def start_prompt(_mount, entry, meta) do
      session_id = "sess-#{meta.schedule_id}-#{next_seq()}"
      Agent.update(@agent, &%{&1 | sessions: MapSet.put(&1.sessions, session_id)})
      launch(entry, meta, {:ok, session_id})
    end

    @impl true
    def start_command(_mount, entry, meta, _owner) do
      Agent.update(
        @agent,
        &%{&1 | commands: MapSet.put(&1.commands, {meta.icm_id, meta.schedule_id})}
      )

      launch(entry, meta, {:ok, self()})
    end

    @impl true
    def live?(_icm_id, _schedule_id, :prompt, %{outcome: "running", session_id: session_id})
        when is_binary(session_id) do
      Agent.get(@agent, &MapSet.member?(&1.sessions, session_id))
    end

    @impl true
    def live?(_icm_id, _schedule_id, :prompt, _no_running_run), do: false

    @impl true
    def live?(icm_id, schedule_id, :command, _last_run) do
      Agent.get(@agent, &MapSet.member?(&1.commands, {icm_id, schedule_id}))
    end

    defp next_seq do
      Agent.get_and_update(@agent, fn s -> {s.seq + 1, %{s | seq: s.seq + 1}} end)
    end

    defp launch(entry, meta, ok) do
      %{test: test, fail: fail} = Agent.get(@agent, & &1)
      send(test, {:fired, entry.id, meta})
      if fail, do: {:error, fail}, else: ok
    end
  end

  setup do
    ws = tmp("ws")
    icm = tmp("icm")

    File.mkdir_p!(Path.join(ws, "config"))

    File.write!(
      Path.join(ws, "config/workspace.yaml"),
      "version: 5\nid: ws-scheduler-test\nname: Test\n"
    )

    # Store-backed Repo, exactly as `Valea.Schedules.StoreTest` boots it: the
    # scheduler needs the two tables, not the full workspace-open lifecycle.
    start_supervised!({Valea.Repo, database: Path.join(ws, "app.sqlite"), pool_size: 1})
    migrate()

    start_supervised!({Valea.Audit, %{root: ws, generation: @generation}})
    # The daily sweep runs through the ledger writer (a sibling child of the
    # scheduler in production).
    start_supervised!(Valea.Ledger.Writer)
    start_supervised!({FakeRunner, self()})

    clock = start_supervised!({Agent, fn -> at("2026-07-30T08:15:00Z") end})

    on_exit(fn ->
      File.rm_rf!(ws)
      File.rm_rf!(icm)
    end)

    %{ws: ws, icm: icm, clock: clock}
  end

  # -- 1. registration ---------------------------------------------------------

  test "a new schedule registers anchors at now, does not fire instantly, fires at its next future slot",
       ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)

    state = state()
    assert state.first_seen_at == at("2026-07-30T08:15:00Z")
    assert state.last_attempted_slot == at("2026-07-30T08:15:00Z")
    assert state.deleted_at == nil
    assert state.fingerprint == Entry.fingerprint(entry_raw())
    refute_received {:fired, _, _}
    assert runs() == []

    tick(ctx, "2026-07-30T09:00:00Z")

    assert_received {:fired, "s1", meta}
    assert meta.slot == at("2026-07-30T09:00:00Z")
    assert meta.trigger == "scheduled"
    assert meta.coalesced_count == 1
    assert meta.icm_id == @icm_id
    assert meta.icm_name == "Work"
    assert meta.mount_key == "work"
    assert meta.generation == @generation

    assert [run] = runs()
    assert run.outcome == "running"
    assert run.kind == "prompt"
    assert run.session_id =~ ~r/^sess-s1-\d+$/
    assert run.trigger == "scheduled"
    assert run.coalesced_count == 1
    assert run.slot == at("2026-07-30T09:00:00Z")
    assert state().last_attempted_slot == at("2026-07-30T09:00:00Z")
  end

  # -- 2. coalescing -----------------------------------------------------------

  test "several elapsed slots fire once, carrying the coalesced count", ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)

    tick(ctx, "2026-07-30T11:05:00Z")

    assert_received {:fired, "s1", meta}
    refute_received {:fired, _, _}
    assert meta.coalesced_count == 3
    assert meta.slot == at("2026-07-30T11:00:00Z")
    assert [%{coalesced_count: 3, slot: ~U[2026-07-30 11:00:00Z]}] = runs()
    assert state().last_attempted_slot == at("2026-07-30T11:00:00Z")
  end

  # -- 3. one run at a time ----------------------------------------------------

  test "due while the previous run is live records ONE skip with the coalesced count and never re-emits",
       ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)

    tick(ctx, "2026-07-30T09:00:00Z")
    assert_received {:fired, "s1", _meta}

    tick(ctx, "2026-07-30T11:05:00Z")

    refute_received {:fired, _, _}
    assert [skip, _running] = runs()
    assert skip.outcome == "skipped: still running"
    assert skip.coalesced_count == 2
    assert skip.slot == at("2026-07-30T11:00:00Z")
    assert state().last_attempted_slot == at("2026-07-30T11:00:00Z")

    # Same clock, still live: no elapsed slots, so nothing new is recorded.
    :ok = Scheduler.tick_now()
    assert length(runs()) == 2
  end

  test "a skip record never hides the live run: further slots keep skipping, never launch a second run",
       ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)

    tick(ctx, "2026-07-30T09:00:00Z")
    assert_received {:fired, "s1", _meta}
    assert [%{outcome: "running", session_id: session}] = runs()

    # First skip: now the NEWEST row for this schedule is the skip, not the run.
    tick(ctx, "2026-07-30T10:00:00Z")
    refute_received {:fired, _, _}

    # The slot that used to break it. Liveness read off the newest row alone sees
    # a skip (outcome "skipped: still running", no session) and answers "not
    # live", so a SECOND session launches here — and again at every later slot.
    tick(ctx, "2026-07-30T11:00:00Z")
    refute_received {:fired, _, _}
    tick(ctx, "2026-07-30T12:00:00Z")
    refute_received {:fired, _, _}

    outcomes = runs() |> Enum.map(& &1.outcome) |> Enum.frequencies()
    assert outcomes == %{"running" => 1, "skipped: still running" => 3}

    # And when the session really ends, the next slot fires again — exactly once.
    FakeRunner.end_session(session)
    tick(ctx, "2026-07-30T13:00:00Z")
    assert_received {:fired, "s1", %{coalesced_count: 1}}
    refute_received {:fired, _, _}
  end

  test "a live COMMAND run is derived from the run registry, not from the newest row", ctx do
    raw = entry_raw(%{"payload" => %{"kind" => "command", "command" => "echo", "args" => ["hi"]}})
    write_schedules(ctx, [raw])
    start_scheduler(ctx)

    tick(ctx, "2026-07-30T09:00:00Z")
    assert_received {:fired, "s1", _meta}

    tick(ctx, "2026-07-30T10:00:00Z")
    tick(ctx, "2026-07-30T11:00:00Z")
    refute_received {:fired, _, _}

    FakeRunner.end_command(@icm_id, "s1")
    tick(ctx, "2026-07-30T12:00:00Z")
    assert_received {:fired, "s1", _meta}
  end

  # -- 4. silent slot consumption ----------------------------------------------

  test "a paused entry consumes slots silently; unpausing fires exactly once, never the gap",
       ctx do
    write_schedules(ctx, [entry_raw(%{"paused" => true})])
    start_scheduler(ctx)

    tick(ctx, "2026-07-30T11:05:00Z")

    refute_received {:fired, _, _}
    assert runs() == []
    assert state().last_attempted_slot == at("2026-07-30T11:00:00Z")

    write_schedules(ctx, [entry_raw(%{"paused" => false})])
    tick(ctx, "2026-07-30T11:05:00Z")
    refute_received {:fired, _, _}

    tick(ctx, "2026-07-30T12:00:00Z")
    assert_received {:fired, "s1", meta}
    assert meta.coalesced_count == 1
    assert meta.slot == at("2026-07-30T12:00:00Z")
    refute_received {:fired, _, _}
  end

  test "a not_executable entry (`paused` as a string) consumes slots silently; repair fires exactly once",
       ctx do
    write_schedules(ctx, [entry_raw(%{"paused" => "true"})])
    start_scheduler(ctx)

    tick(ctx, "2026-07-30T11:05:00Z")

    refute_received {:fired, _, _}
    assert runs() == []
    # The `paused` failure aborts validation before the cron is parsed, so this
    # entry has no slots to walk and silent consumption degenerates to
    # consuming elapsed TIME (anchor := now). Equivalent for firing: `now` is
    # never before the last elapsed slot, so the next slot after either is the
    # same one.
    assert state().last_attempted_slot == at("2026-07-30T11:05:00Z")

    write_schedules(ctx, [entry_raw(%{"paused" => false})])
    tick(ctx, "2026-07-30T12:00:00Z")

    assert_received {:fired, "s1", meta}
    assert meta.coalesced_count == 1
    assert meta.slot == at("2026-07-30T12:00:00Z")
    refute_received {:fired, _, _}
  end

  test "duplicate ids consume slots silently; resolving the duplicate fires exactly once", ctx do
    # Same execution fields (so the same fingerprint), different titles: removing
    # one carrier must not read as a definition change.
    write_schedules(ctx, [entry_raw(), entry_raw(%{"title" => "Copy"})])
    start_scheduler(ctx)

    tick(ctx, "2026-07-30T11:05:00Z")

    refute_received {:fired, _, _}
    assert runs() == []
    assert state().last_attempted_slot == at("2026-07-30T11:00:00Z")

    write_schedules(ctx, [entry_raw()])
    tick(ctx, "2026-07-30T12:00:00Z")

    assert_received {:fired, "s1", meta}
    assert meta.coalesced_count == 1
    assert state().first_seen_at == at("2026-07-30T08:15:00Z")
    refute_received {:fired, _, _}
  end

  # -- 5. fingerprint ----------------------------------------------------------

  test "editing the cron resets the anchors to now and never back-fires", ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)

    edited = entry_raw(%{"cron" => "*/30 * * * *"})
    write_schedules(ctx, [edited])
    tick(ctx, "2026-07-30T09:30:00Z")

    refute_received {:fired, _, _}
    state = state()
    assert state.first_seen_at == at("2026-07-30T09:30:00Z")
    assert state.last_attempted_slot == at("2026-07-30T09:30:00Z")
    assert state.fingerprint == Entry.fingerprint(edited)
  end

  test "editing only the title does NOT reset the anchors — the fire lands on time", ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)

    write_schedules(ctx, [entry_raw(%{"title" => "Renamed"})])
    tick(ctx, "2026-07-30T09:30:00Z")

    assert_received {:fired, "s1", meta}
    assert meta.slot == at("2026-07-30T09:00:00Z")
    assert state().first_seen_at == at("2026-07-30T08:15:00Z")
  end

  # -- 6. tombstones -----------------------------------------------------------

  test "an id vanishing from a parseable file tombstones it; identical recreation resets anchors",
       ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)

    write_schedules(ctx, [])
    tick(ctx, "2026-07-30T09:30:00Z")

    assert state().deleted_at == at("2026-07-30T09:30:00Z")
    refute_received {:fired, _, _}

    # Byte-identical recreation: same fingerprint, but the tombstone still
    # forces a full reset — no catch-up across the gap.
    write_schedules(ctx, [entry_raw()])
    tick(ctx, "2026-07-30T11:30:00Z")

    state = state()
    assert state.deleted_at == nil
    assert state.first_seen_at == at("2026-07-30T11:30:00Z")
    assert state.last_attempted_slot == at("2026-07-30T11:30:00Z")
    refute_received {:fired, _, _}

    tick(ctx, "2026-07-30T12:00:00Z")
    assert_received {:fired, "s1", meta}
    assert meta.coalesced_count == 1
  end

  test "an unreadable file never tombstones and audits once per content hash", ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)

    File.write!(schedules_path(ctx), "{ not json")
    tick(ctx, "2026-07-30T09:30:00Z")

    assert state().deleted_at == nil
    assert state().last_attempted_slot == at("2026-07-30T08:15:00Z")
    assert count_audits("schedules_unreadable") == 1

    tick(ctx, "2026-07-30T09:31:00Z")
    assert count_audits("schedules_unreadable") == 1

    File.write!(schedules_path(ctx), "{ still not json")
    tick(ctx, "2026-07-30T09:32:00Z")
    assert count_audits("schedules_unreadable") == 2
  end

  test "an absent file never tombstones", ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)

    File.rm!(schedules_path(ctx))
    tick(ctx, "2026-07-30T09:30:00Z")

    assert state().deleted_at == nil
    assert count_audits("schedules_unreadable") == 0
  end

  # -- 7. catch-up: catchup false ---------------------------------------------

  test "catchup false fast-forwards the anchor on open — missed slots are consumed silently",
       ctx do
    write_schedules(ctx, [entry_raw()])
    seed_state("s1", entry_raw(), "2026-07-30T04:00:00Z", "2026-07-30T06:00:00Z")

    start_scheduler(ctx)

    assert state().last_attempted_slot == at("2026-07-30T08:15:00Z")
    refute_received {:fired, _, _}
    assert runs() == []
  end

  test "the anchor is monotonic: a backward clock jump on open leaves it where it was", ctx do
    write_schedules(ctx, [entry_raw()])
    seed_state("s1", entry_raw(), "2026-07-30T04:00:00Z", "2026-07-30T10:00:00Z")
    Agent.update(ctx.clock, fn _ -> at("2026-07-30T08:00:00Z") end)

    start_scheduler(ctx)

    assert state().last_attempted_slot == at("2026-07-30T10:00:00Z")
    refute_received {:fired, _, _}
  end

  # -- 8. catch-up: catchup true ----------------------------------------------

  test "catchup true produces one coalesced fire with trigger \"catchup\"", ctx do
    raw = entry_raw(%{"catchup" => true})
    write_schedules(ctx, [raw])
    seed_state("s1", raw, "2026-07-30T06:00:00Z", "2026-07-30T08:00:00Z")
    Agent.update(ctx.clock, fn _ -> at("2026-07-30T11:05:00Z") end)

    start_scheduler(ctx)

    assert_received {:fired, "s1", meta}
    refute_received {:fired, _, _}
    assert meta.trigger == "catchup"
    assert meta.coalesced_count == 3
    assert meta.slot == at("2026-07-30T11:00:00Z")
    assert [%{trigger: "catchup", coalesced_count: 3}] = runs()
    assert state().last_attempted_slot == at("2026-07-30T11:00:00Z")
  end

  # -- 9. kill switch ----------------------------------------------------------

  test "the workspace kill switch consumes slots silently for every entry and never back-fires",
       ctx do
    write_schedules(ctx, [entry_raw(), entry_raw(%{"id" => "s2"})])
    start_scheduler(ctx)
    :ok = Valea.Mounts.set_scheduler_paused(ctx.ws, true)
    assert Valea.Mounts.scheduler_paused?(ctx.ws)

    tick(ctx, "2026-07-30T11:05:00Z")

    refute_received {:fired, _, _}
    assert runs() == []
    assert runs("s2") == []
    assert state().last_attempted_slot == at("2026-07-30T11:00:00Z")
    assert state("s2").last_attempted_slot == at("2026-07-30T11:00:00Z")

    :ok = Valea.Mounts.set_scheduler_paused(ctx.ws, false)
    refute Valea.Mounts.scheduler_paused?(ctx.ws)
    tick(ctx, "2026-07-30T11:05:00Z")
    refute_received {:fired, _, _}

    tick(ctx, "2026-07-30T12:00:00Z")
    assert_received {:fired, "s1", %{coalesced_count: 1}}
    assert_received {:fired, "s2", %{coalesced_count: 1}}
  end

  # -- 10. launch-time re-validation ------------------------------------------

  test "a pause landing between due-computation and launch stops the fire and consumes nothing",
       ctx do
    write_schedules(ctx, [entry_raw()])

    start_scheduler(ctx,
      before_launch: fn -> write_schedules(ctx, [entry_raw(%{"paused" => true})]) end
    )

    tick(ctx, "2026-07-30T09:00:00Z")

    refute_received {:fired, _, _}
    assert runs() == []
    assert state().last_attempted_slot == at("2026-07-30T08:15:00Z")
  end

  test "a kill switch engaged between due-computation and launch stops the fire", ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx, before_launch: fn -> Valea.Mounts.set_scheduler_paused(ctx.ws, true) end)

    tick(ctx, "2026-07-30T09:00:00Z")

    refute_received {:fired, _, _}
    assert runs() == []
    assert state().last_attempted_slot == at("2026-07-30T08:15:00Z")
  end

  test "a definition edited between due-computation and launch stops the fire", ctx do
    write_schedules(ctx, [entry_raw()])

    start_scheduler(ctx,
      before_launch: fn -> write_schedules(ctx, [entry_raw(%{"cron" => "*/5 * * * *"})]) end
    )

    tick(ctx, "2026-07-30T09:00:00Z")

    refute_received {:fired, _, _}
    assert runs() == []
  end

  # -- 11. run_now -------------------------------------------------------------

  test "run_now fires an executable entry with trigger \"manual\" and does not advance the anchor",
       ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)

    assert {:ok, run_id} = Scheduler.run_now(@icm_id, "s1")

    assert_received {:fired, "s1", meta}
    assert meta.trigger == "manual"
    assert meta.coalesced_count == 1
    assert [%{id: ^run_id, trigger: "manual", outcome: "running", session_id: session}] = runs()
    assert session =~ ~r/^sess-s1-\d+$/
    assert state().last_attempted_slot == at("2026-07-30T08:15:00Z")
  end

  test "run_now fires a PAUSED entry — an explicit human override", ctx do
    write_schedules(ctx, [entry_raw(%{"paused" => true})])
    start_scheduler(ctx)

    assert {:ok, _run_id} = Scheduler.run_now(@icm_id, "s1")
    assert_received {:fired, "s1", %{trigger: "manual"}}
  end

  test "run_now rejects a not_executable entry, a duplicate, an unknown id and a live run", ctx do
    write_schedules(ctx, [
      entry_raw(%{"id" => "broken", "cron" => "not a cron"}),
      entry_raw(%{"id" => "dup"}),
      entry_raw(%{"id" => "dup", "title" => "Copy"}),
      entry_raw()
    ])

    start_scheduler(ctx)

    assert {:error, :not_executable} = Scheduler.run_now(@icm_id, "broken")
    assert {:error, :not_executable} = Scheduler.run_now(@icm_id, "dup")
    assert {:error, :not_found} = Scheduler.run_now(@icm_id, "nope")
    assert {:error, :not_found} = Scheduler.run_now("other-icm", "s1")
    refute_received {:fired, _, _}

    # A live run blocks a manual one — with the run made live the honest way, by
    # running it.
    assert {:ok, _run_id} = Scheduler.run_now(@icm_id, "s1")
    assert_received {:fired, "s1", _meta}
    assert {:error, :already_running} = Scheduler.run_now(@icm_id, "s1")
    refute_received {:fired, _, _}
  end

  # -- 12. audit ---------------------------------------------------------------

  test "registration, fires and skips are audited", ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)

    assert count_audits("schedule_registered_changed") == 1

    assert %{"mount_key" => "work", "schedule_id" => "s1", "created_by" => nil} =
             audit("schedule_registered_changed")

    tick(ctx, "2026-07-30T09:00:00Z")
    assert %{"schedule_id" => "s1", "trigger" => "scheduled"} = audit("schedule_fired")

    # The session started above is still live, so the next slot skips.
    tick(ctx, "2026-07-30T10:00:00Z")
    assert %{"schedule_id" => "s1"} = audit("schedule_skipped")

    write_schedules(ctx, [])
    tick(ctx, "2026-07-30T10:01:00Z")
    assert %{"change" => "deleted"} = audit("schedule_registered_changed")
  end

  # -- convergence of runs left behind (crash, workspace close) ----------------

  test "a stale running row converges to interrupted even when a newer skip record hides it",
       ctx do
    write_schedules(ctx, [entry_raw()])
    seed_state("s1", entry_raw(), "2026-07-30T04:00:00Z", "2026-07-30T06:00:00Z")

    # What a killed workspace leaves behind: a command run recorded `running`,
    # and a later skip event on top of it. Reading only the newest row (a skip)
    # never sees the row that needs converging.
    {:ok, stale} =
      Store.record_run(%{
        icm_id: @icm_id,
        schedule_id: "s1",
        kind: "command",
        outcome: "running",
        fired_at: at("2026-07-30T07:00:00Z"),
        slot: at("2026-07-30T07:00:00Z"),
        trigger: "scheduled",
        mount_key: "work"
      })

    {:ok, _skip} =
      Store.record_run(%{
        icm_id: @icm_id,
        schedule_id: "s1",
        kind: "command",
        outcome: "skipped: still running",
        fired_at: at("2026-07-30T08:00:00Z"),
        slot: at("2026-07-30T08:00:00Z"),
        trigger: "scheduled",
        mount_key: "work"
      })

    start_scheduler(ctx)

    assert %{outcome: "interrupted"} = Enum.find(runs(), &(&1.id == stale))
  end

  test "a stale running PROMPT row converges when its session is gone, and is left alone when it is not",
       ctx do
    write_schedules(ctx, [entry_raw(), entry_raw(%{"id" => "s2"})])

    {:ok, dead} = seed_running_prompt("s1", "ghost-session")
    {:ok, alive} = seed_running_prompt("s2", "held-session")
    FakeRunner.mark_session_live("held-session")

    start_scheduler(ctx)

    assert %{outcome: "interrupted"} = Enum.find(runs("s1"), &(&1.id == dead))
    assert %{outcome: "running"} = Enum.find(runs("s2"), &(&1.id == alive))
  end

  test "terminate marks every still-running row interrupted, prompt runs included", ctx do
    write_schedules(ctx, [entry_raw(), entry_raw(%{"id" => "s2"})])
    start_scheduler(ctx)

    tick(ctx, "2026-07-30T09:00:00Z")
    assert [%{outcome: "running"}] = runs()
    assert [%{outcome: "running"}] = runs("s2")

    stop_supervised!(Scheduler)

    assert [%{outcome: "interrupted"}] = runs()
    assert [%{outcome: "interrupted"}] = runs("s2")
  end

  # -- a mount's first pass is per MOUNT, not per process ----------------------

  test "a file unreadable at boot still gets its catch-up when repaired — no back-fire", ctx do
    seed_state("s1", entry_raw(), "2026-07-30T04:00:00Z", "2026-07-30T06:00:00Z")
    File.write!(schedules_path(ctx), "{ not json")

    start_scheduler(ctx)
    assert state().last_attempted_slot == at("2026-07-30T06:00:00Z")

    # Repaired three hours later: this is the mount's FIRST readable pass, so
    # `catchup: false` fast-forwards. Treating "the process already ticked" as
    # "this mount already caught up" would instead walk 07:00..11:00 and fire.
    write_schedules(ctx, [entry_raw()])
    tick(ctx, "2026-07-30T11:05:00Z")

    refute_received {:fired, _, _}
    assert runs() == []
    assert state().last_attempted_slot == at("2026-07-30T11:05:00Z")
  end

  test "a mount absent at boot still gets its catch-up when it appears — no back-fire", ctx do
    seed_state("s1", entry_raw(), "2026-07-30T04:00:00Z", "2026-07-30T06:00:00Z")
    write_schedules(ctx, [entry_raw()])

    mounted = start_supervised!(Supervisor.child_spec({Agent, fn -> false end}, id: :mounted))

    start_scheduler(ctx,
      mounts_fun: fn ->
        if Agent.get(mounted, & &1), do: {:ok, [mount(ctx)]}, else: {:ok, []}
      end
    )

    assert state().last_attempted_slot == at("2026-07-30T06:00:00Z")

    Agent.update(mounted, fn _ -> true end)
    tick(ctx, "2026-07-30T11:05:00Z")

    refute_received {:fired, _, _}
    assert state().last_attempted_slot == at("2026-07-30T11:05:00Z")
  end

  test "catchup true still fires on the mount's first READABLE pass, labelled catchup", ctx do
    raw = entry_raw(%{"catchup" => true})
    seed_state("s1", raw, "2026-07-30T06:00:00Z", "2026-07-30T08:00:00Z")
    File.write!(schedules_path(ctx), "{ not json")

    start_scheduler(ctx)
    refute_received {:fired, _, _}

    write_schedules(ctx, [raw])
    tick(ctx, "2026-07-30T11:05:00Z")

    assert_received {:fired, "s1", %{trigger: "catchup", coalesced_count: 3}}
  end

  # -- the kill switch fails closed --------------------------------------------

  test "an unparseable workspace.yaml pauses everything and audits once", ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)

    File.write!(Path.join(ctx.ws, "config/workspace.yaml"), "icms: [oops\n  bad: :\n")
    tick(ctx, "2026-07-30T11:05:00Z")

    refute_received {:fired, _, _}
    assert runs() == []
    assert state().last_attempted_slot == at("2026-07-30T11:00:00Z")
    assert count_audits("scheduler_config_unreadable") == 1

    tick(ctx, "2026-07-30T11:06:00Z")
    assert count_audits("scheduler_config_unreadable") == 1

    # Repaired: firing resumes, and the missed slots stay consumed.
    File.write!(Path.join(ctx.ws, "config/workspace.yaml"), "version: 5\nname: Test\n")
    tick(ctx, "2026-07-30T12:00:00Z")
    assert_received {:fired, "s1", %{coalesced_count: 1}}
  end

  # -- run_now goes through step 7 ---------------------------------------------

  test "run_now re-validates: a definition edited inside the launch window fires nothing", ctx do
    write_schedules(ctx, [entry_raw()])

    start_scheduler(ctx,
      before_launch: fn -> write_schedules(ctx, [entry_raw(%{"cron" => "*/5 * * * *"})]) end
    )

    assert {:error, :not_executable} = Scheduler.run_now(@icm_id, "s1")
    refute_received {:fired, _, _}
    assert runs() == []
  end

  test "run_now re-validates: an entry deleted inside the launch window fires nothing", ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx, before_launch: fn -> write_schedules(ctx, []) end)

    assert {:error, :not_executable} = Scheduler.run_now(@icm_id, "s1")
    refute_received {:fired, _, _}
    assert runs() == []
  end

  test "run_now refuses while the kill switch is engaged", ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)
    :ok = Valea.Mounts.set_scheduler_paused(ctx.ws, true)

    assert {:error, :scheduler_paused} = Scheduler.run_now(@icm_id, "s1")
    refute_received {:fired, _, _}
    assert runs() == []
  end

  # -- spawn failures, generation binding, sweeps ------------------------------

  test "a spawn error marks the run failed with the detail in output, audits, and advances the anchor",
       ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx)
    FakeRunner.fail(:boom)

    tick(ctx, "2026-07-30T09:00:00Z")

    assert [run] = runs()
    assert run.outcome == "failed"
    assert run.output =~ "boom"
    assert state().last_attempted_slot == at("2026-07-30T09:00:00Z")
    assert %{"schedule_id" => "s1"} = audit("schedule_run_failed")
  end

  test "a stale workspace generation writes nothing and launches nothing", ctx do
    write_schedules(ctx, [entry_raw()])
    start_scheduler(ctx, generation_fun: fn _gen -> {:error, :workspace_changed} end)

    assert state() == nil

    tick(ctx, "2026-07-30T09:00:00Z")
    refute_received {:fired, _, _}
    assert runs() == []
  end

  test "the first tick sweeps stale completed tasks per ICM", ctx do
    write_schedules(ctx, [entry_raw()])

    File.write!(
      Path.join(ctx.icm, "tasks.json"),
      Jason.encode!(%{
        "tasks" => [
          %{
            "id" => "t-old",
            "title" => "Long done",
            "status" => "done",
            "done_at" => "2026-06-01T10:00:00Z"
          }
        ]
      })
    )

    start_scheduler(ctx)

    assert %{status: :ok, tasks: []} = Valea.Tasks.list(ctx.icm)
    assert File.read!(Valea.Tasks.archive_path(ctx.icm)) =~ "t-old"
  end

  test "a command payload records kind \"command\" and goes through start_command", ctx do
    raw =
      entry_raw(%{
        "payload" => %{"kind" => "command", "command" => "echo", "args" => ["hi"]}
      })

    write_schedules(ctx, [raw])
    start_scheduler(ctx)

    tick(ctx, "2026-07-30T09:00:00Z")

    assert_received {:fired, "s1", _meta}
    assert [%{kind: "command", outcome: "running", session_id: nil}] = runs()
  end

  test "a command run's completion message updates the run record", ctx do
    raw =
      entry_raw(%{
        "payload" => %{"kind" => "command", "command" => "echo", "args" => ["hi"]}
      })

    write_schedules(ctx, [raw])
    start_scheduler(ctx)
    tick(ctx, "2026-07-30T09:00:00Z")
    assert [%{id: run_id}] = runs()

    send(Scheduler, {:run_finished, run_id, "completed", 42, "hi\n"})
    # A call after the send: the cast-shaped message is handled first.
    :ok = Scheduler.tick_now()

    # `output` comes back trimmed — Ash's `:string` type trims by default. Fine
    # for captured output; it is the reason detail must never ride the outcome.
    assert [%{outcome: "completed", duration_ms: 42, output: "hi"}] = runs()
    assert %{"run_id" => ^run_id, "outcome" => "completed"} = audit("schedule_run_finished")
  end

  test "a completion arriving after a workspace switch writes and audits nothing", ctx do
    raw =
      entry_raw(%{
        "payload" => %{"kind" => "command", "command" => "echo", "args" => ["hi"]}
      })

    write_schedules(ctx, [raw])
    # A distinct child id: the clock in `setup` already claims `Agent`.
    stale =
      start_supervised!(Supervisor.child_spec({Agent, fn -> :ok end}, id: :stale_generation))

    start_scheduler(ctx, generation_fun: fn _gen -> Agent.get(stale, & &1) end)

    tick(ctx, "2026-07-30T09:00:00Z")
    assert [%{id: run_id, outcome: "running"}] = runs()

    # The switch lands, then the run finishes.
    Agent.update(stale, fn _ -> {:error, :workspace_changed} end)
    send(Scheduler, {:run_finished, run_id, "completed", 42, "hi"})
    :ok = Scheduler.tick_now()

    assert [%{outcome: "running"}] = runs()
    assert audit("schedule_run_finished") == nil
  end

  # -- helpers -----------------------------------------------------------------

  defp tmp(kind) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-scheduler-#{kind}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp migrate do
    path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    previous = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, path, :up, all: true)
    Code.compiler_options(previous)
  end

  defp at(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    DateTime.truncate(dt, :second)
  end

  defp entry_raw(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "s1",
        "title" => "Morning",
        "cron" => "0 * * * *",
        "timezone" => "Etc/UTC",
        "payload" => %{"kind" => "prompt", "prompt" => "check the inbox"}
      },
      overrides
    )
  end

  defp schedules_path(ctx), do: Path.join(ctx.icm, "schedules.json")

  defp write_schedules(ctx, entries) do
    File.write!(schedules_path(ctx), Jason.encode!(%{"schedules" => entries}))
  end

  defp mount(ctx) do
    %{
      name: "work",
      root: ctx.icm,
      manifest: %Valea.Mounts.Manifest{format: 2, id: @icm_id, name: "Work"},
      enabled: true,
      degraded: nil,
      kind: :icm
    }
  end

  defp start_scheduler(ctx, opts \\ []) do
    cfg = %{
      root: ctx.ws,
      generation: @generation,
      # No spontaneous ticks: every tick in these tests is driven by
      # `tick_now/0` (or the boot tick).
      tick_ms: 3_600_000,
      now_fun: fn -> Agent.get(ctx.clock, & &1) end,
      runner: FakeRunner,
      mounts_fun: fn -> {:ok, [mount(ctx)]} end,
      generation_fun: fn _gen -> :ok end
    }

    pid = start_supervised!({Scheduler, Map.merge(cfg, Map.new(opts))})
    # Queues behind the boot tick's `handle_continue`, so every assertion below
    # sees a completed first tick.
    _ = :sys.get_state(pid)
    pid
  end

  defp tick(ctx, iso) do
    Agent.update(ctx.clock, fn _ -> at(iso) end)
    :ok = Scheduler.tick_now()
  end

  # Pre-seeds persisted state as a previous workspace session would have left
  # it. The fingerprint must match the file's, or reconciliation resets it.
  defp seed_state(schedule_id, raw, first_seen, anchor) do
    Store.put_state(@icm_id, schedule_id, %{
      fingerprint: Entry.fingerprint(raw),
      first_seen_at: at(first_seen),
      last_attempted_slot: at(anchor)
    })
  end

  # A run row left behind by a previous workspace session.
  defp seed_running_prompt(schedule_id, session_id) do
    Store.record_run(%{
      icm_id: @icm_id,
      schedule_id: schedule_id,
      kind: "prompt",
      outcome: "running",
      session_id: session_id,
      fired_at: at("2026-07-30T07:00:00Z"),
      slot: at("2026-07-30T07:00:00Z"),
      trigger: "scheduled",
      mount_key: "work"
    })
  end

  defp state(schedule_id \\ "s1"), do: Store.get_state(@icm_id, schedule_id)
  defp runs(schedule_id \\ "s1"), do: Store.runs(@icm_id, schedule_id, 50)

  defp audits do
    {:ok, entries} = Valea.Audit.entries(200)
    entries
  end

  defp count_audits(type), do: audits() |> Enum.count(&(&1["type"] == type))
  defp audit(type), do: audits() |> Enum.find(&(&1["type"] == type))
end
