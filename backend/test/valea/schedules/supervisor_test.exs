defmodule Valea.Schedules.SupervisorTest do
  # async: false — every process here is registered under its module name.
  use ExUnit.Case, async: false

  alias Valea.PlatformFixtures
  alias Valea.Schedules.Runner
  alias Valea.Schedules.Scheduler
  alias Valea.Schedules.Store

  @icm_id "7c1de3aa-0000-4000-8000-0000000000bb"
  @generation 3

  # The real thing: the whole `Valea.Schedules.Supervisor` tree, the real
  # `Runner.Live`, and a real subprocess. Only the clock, the mount listing and
  # the generation check are stubbed, because everything this file is about
  # happens BETWEEN those processes — a scheduler crash while a command run keeps
  # going, and the run's outcome finding its way back to the replacement.
  setup do
    ws = tmp("ws")
    icm = tmp("icm")

    File.mkdir_p!(Path.join(ws, "config"))
    File.write!(Path.join(ws, "config/workspace.yaml"), "version: 5\nid: ws-sup\nname: Test\n")

    start_supervised!({Valea.Repo, database: Path.join(ws, "app.sqlite"), pool_size: 1})
    migrate()
    start_supervised!({Valea.Audit, %{root: ws, generation: @generation}})

    gate = Path.join(icm, "gate")

    script =
      PlatformFixtures.script!(
        icm,
        "gated",
        "while [ ! -f gate ]; do sleep 0.05; done\necho released\n",
        "@echo off\r\n:loop\r\nif exist gate goto done\r\nping -n 1 127.0.0.1 >nul\r\ngoto loop\r\n:done\r\necho released\r\n"
      )

    File.write!(
      Path.join(icm, "schedules.json"),
      Jason.encode!(%{
        "schedules" => [
          %{
            "id" => "s1",
            "title" => "Sync",
            "cron" => "0 * * * *",
            "timezone" => "Etc/UTC",
            "payload" => %{
              "kind" => "command",
              "command" => "./" <> Path.basename(script),
              "args" => []
            }
          }
        ]
      })
    )

    on_exit(fn ->
      File.rm_rf!(ws)
      File.rm_rf!(icm)
    end)

    %{ws: ws, icm: icm, gate: gate}
  end

  test "the tree wires up the writer, the run registry, the run supervisor and the scheduler",
       ctx do
    start_tree(ctx)

    assert Process.whereis(Valea.Ledger.Writer)
    assert Process.whereis(Valea.Schedules.RunRegistry)
    assert Process.whereis(Valea.Schedules.RunSupervisor)
    assert Process.whereis(Scheduler)

    # Start order is load-bearing: the scheduler is started LAST, so on shutdown
    # it is terminated FIRST — while the registry and the run processes it reads
    # are still alive. `which_children/1` reports newest-first, so the scheduler
    # heads the list and the writer (started first, stopped last) ends it.
    ids = Supervisor.which_children(Valea.Schedules.Supervisor) |> Enum.map(&elem(&1, 0))
    assert List.first(ids) == Scheduler
    assert List.last(ids) == Valea.Ledger.Writer
  end

  test "a scheduler crash leaves a live command run alone, and its outcome still lands", ctx do
    start_tree(ctx)

    assert {:ok, run_id} = Scheduler.run_now(@icm_id, "s1")
    assert [%{outcome: "running"}] = runs()
    assert Runner.Live.live?(@icm_id, "s1", :command, nil)

    first = Process.whereis(Scheduler)
    Process.exit(first, :kill)
    second = await_restart(first)

    # The run process survived (the tree is `:one_for_one`), so the replacement
    # scheduler's first pass must NOT converge this row: it is not stale, it is
    # running. Marking it `interrupted` here would destroy a live run's record
    # AND clear the way for a second concurrent run at the next slot.
    assert Runner.Live.live?(@icm_id, "s1", :command, nil)
    assert [%{outcome: "running"}] = runs()

    # And the outcome reaches the REPLACEMENT: `CommandRun` reports to the
    # registered scheduler name, not to the pid that started it (now a corpse).
    File.touch!(ctx.gate)

    assert %{outcome: "completed", output: output} = await_outcome(run_id)
    assert output =~ "released"
    assert second == Process.whereis(Scheduler)
  end

  test "a run left running with nothing behind it converges to interrupted on the first pass",
       ctx do
    # No `CommandRun` for this row — what a killed workspace leaves behind.
    {:ok, orphan} =
      Store.record_run(%{
        icm_id: @icm_id,
        schedule_id: "s1",
        kind: "command",
        outcome: "running",
        fired_at: ~U[2026-07-30 07:00:00Z],
        slot: ~U[2026-07-30 07:00:00Z],
        trigger: "scheduled",
        mount_key: "work"
      })

    start_tree(ctx)

    assert %{outcome: "interrupted"} = Enum.find(runs(), &(&1.id == orphan))
  end

  # -- helpers -----------------------------------------------------------------

  defp start_tree(ctx) do
    start_supervised!(
      {Valea.Schedules.Supervisor,
       %{
         root: ctx.ws,
         generation: @generation,
         tick_ms: 3_600_000,
         now_fun: fn -> ~U[2026-07-30 08:15:00Z] end,
         mounts_fun: fn -> {:ok, [mount(ctx)]} end,
         generation_fun: fn _gen -> :ok end
       }}
    )

    _ = :sys.get_state(Scheduler)
    :ok
  end

  defp await_restart(old_pid, attempts \\ 200) do
    case Process.whereis(Scheduler) do
      pid when is_pid(pid) and pid != old_pid ->
        # Sync on the replacement's own first tick before asserting on its work.
        _ = :sys.get_state(pid)
        pid

      _not_yet when attempts > 0 ->
        Process.sleep(25)
        await_restart(old_pid, attempts - 1)

      _giving_up ->
        flunk("scheduler never restarted")
    end
  end

  defp await_outcome(run_id, attempts \\ 400) do
    row = Enum.find(runs(), &(&1.id == run_id))

    cond do
      row && row.outcome != "running" -> row
      attempts > 0 -> Process.sleep(25) && await_outcome(run_id, attempts - 1)
      true -> flunk("run #{run_id} never left `running` (last seen: #{inspect(row)})")
    end
  end

  defp runs, do: Store.runs(@icm_id, "s1", 20)

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

  defp migrate do
    path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    previous = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, path, :up, all: true)
    Code.compiler_options(previous)
  end

  defp tmp(kind) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-sched-sup-#{kind}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end
end
