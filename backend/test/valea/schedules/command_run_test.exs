defmodule Valea.Schedules.CommandRunTest do
  # async: false — the Registry and the run DynamicSupervisor are named.
  use ExUnit.Case, async: false

  alias Valea.Schedules.CommandRun
  alias Valea.Schedules.Entry
  alias Valea.Schedules.Runner
  alias Valea.PlatformFixtures

  @icm_id "3b6c9f10-0000-4000-8000-0000000000aa"

  setup do
    ws = tmp("ws")
    icm = tmp("icm")

    start_supervised!({Registry, keys: :unique, name: Valea.Schedules.RunRegistry})

    start_supervised!(
      {DynamicSupervisor, name: Valea.Schedules.RunSupervisor, strategy: :one_for_one}
    )

    on_exit(fn ->
      File.rm_rf!(ws)
      File.rm_rf!(icm)
    end)

    %{ws: ws, icm: icm}
  end

  test "captures stdout and stderr, reports completed on exit 0", ctx do
    script =
      PlatformFixtures.script!(
        ctx.icm,
        "ok",
        "echo out-line\necho err-line 1>&2\nexit 0\n",
        "@echo off\r\necho out-line\r\necho err-line 1>&2\r\nexit /b 0\r\n"
      )

    {:ok, _pid} = start_run(ctx, Path.basename(script))

    assert_receive {:run_finished, "run-1", "completed", duration, output}, 5_000
    assert duration >= 0
    assert output =~ "out-line"
    assert output =~ "err-line"
  end

  test "a non-zero exit is failed, with the exit status in the output (never in the outcome)",
       ctx do
    script =
      PlatformFixtures.script!(
        ctx.icm,
        "bad",
        "echo nope\nexit 3\n",
        "@echo off\r\necho nope\r\nexit /b 3\r\n"
      )

    {:ok, _pid} = start_run(ctx, Path.basename(script))

    assert_receive {:run_finished, "run-1", outcome, _duration, output}, 5_000
    # Exact token — the notice feed matches by equality.
    assert outcome == "failed"
    assert output =~ "nope"
    assert output =~ "exit status 3"
  end

  test "the timeout kills the subprocess and reports timed out", ctx do
    script =
      PlatformFixtures.script!(
        ctx.icm,
        "slow",
        "sleep 30\n",
        "@echo off\r\nping -n 30 127.0.0.1 >nul\r\n"
      )

    {:ok, _pid} = start_run(ctx, Path.basename(script), timeout_ms: 50)

    assert_receive {:run_finished, "run-1", "timed out", _duration, output}, 5_000
    assert output =~ "killed on timeout"
  end

  @tag :unix_only
  test "output is capped at 256 KiB with one marker", ctx do
    script =
      PlatformFixtures.script!(
        ctx.icm,
        "loud",
        "i=0\nwhile [ $i -lt 400 ]; do printf 'x%.0s' $(seq 1 1024); i=$((i+1)); done\n",
        "@echo off\r\n"
      )

    {:ok, _pid} = start_run(ctx, Path.basename(script))

    assert_receive {:run_finished, "run-1", _outcome, _duration, output}, 20_000
    assert String.ends_with?(output, "[output capped]")
    assert byte_size(output) <= 262_144 + byte_size("\n[output capped]")
    # Exactly one marker, however many chunks arrived after the cap.
    assert output |> String.split("[output capped]") |> length() == 2
  end

  test "the Registry key makes a second run of the same schedule refuse", ctx do
    script =
      PlatformFixtures.script!(
        ctx.icm,
        "slow",
        "sleep 5\n",
        "@echo off\r\nping -n 5 127.0.0.1 >nul\r\n"
      )

    entry = entry(Path.basename(script))
    meta = meta(ctx)

    assert {:ok, _pid} = Runner.Live.start_command(mount(ctx), entry, meta, self())
    assert Runner.Live.live?(@icm_id, "s1", :command, nil)
    assert {:error, :already_running} = Runner.Live.start_command(mount(ctx), entry, meta, self())
  end

  test "an unresolvable executable never starts a run", ctx do
    assert {:error, {:spawn_failed, reason}} =
             Runner.Live.start_command(
               mount(ctx),
               entry("definitely-not-a-real-binary-xyz"),
               meta(ctx),
               self()
             )

    assert reason =~ "not found"
    refute Runner.Live.live?(@icm_id, "s1", :command, nil)
  end

  test "an absolute command is taken as named", ctx do
    entry = entry(PlatformFixtures.host_executable!(), ["--version"])
    assert {:ok, _pid} = Runner.Live.start_command(mount(ctx), entry, meta(ctx), self())
    assert_receive {:run_finished, "run-1", _outcome, _duration, _output}, 5_000
  end

  # Prompt liveness is read off the SESSION registry (never the Manager, never a
  # flag the scheduler keeps): a live registration means the run is still going.
  describe "live?/4 for prompt runs" do
    test "false with no run record, and with a run that carries no session" do
      refute Runner.Live.live?(@icm_id, "s1", :prompt, nil)
      refute Runner.Live.live?(@icm_id, "s1", :prompt, %{outcome: "running", session_id: nil})
      refute Runner.Live.live?(@icm_id, "s1", :prompt, %{outcome: "running", session_id: "ghost"})
    end

    test "true while the session process is registered, false once it is gone" do
      id = "sess-#{System.unique_integer([:positive])}"
      test = self()

      session =
        spawn(fn ->
          {:ok, _} = Registry.register(Valea.Agents.SessionRegistry, id, %{input: nil})
          send(test, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered, 1_000
      last_run = %{outcome: "running", session_id: id}
      assert Runner.Live.live?(@icm_id, "s1", :prompt, last_run)

      send(session, :stop)
      ref = Process.monitor(session)
      assert_receive {:DOWN, ^ref, :process, ^session, _reason}, 1_000

      refute Runner.Live.live?(@icm_id, "s1", :prompt, last_run)
    end

    test "a finished run never reads as live" do
      refute Runner.Live.live?(@icm_id, "s1", :prompt, %{outcome: "completed", session_id: "x"})
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp start_run(ctx, command, opts \\ []) do
    args =
      %{mount: mount(ctx), entry: entry(command), meta: meta(ctx), owner: self()}
      |> Map.merge(Map.new(opts))

    DynamicSupervisor.start_child(Valea.Schedules.RunSupervisor, {CommandRun, args})
  end

  # An ICM-root-relative command (the script fixtures live at the ICM root), so
  # these also pin "resolves like a terminal would" for the relative case.
  defp entry(command, args \\ []) do
    %Entry{
      id: "s1",
      title: "Sync",
      payload: %{kind: :command, command: relative(command), args: args},
      disposition: :executable,
      fingerprint: "fp1",
      paused: false,
      catchup: false,
      raw: %{}
    }
  end

  defp relative(command) do
    if Path.type(command) == :absolute, do: command, else: "./" <> command
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

  defp meta(ctx) do
    %{
      icm_id: @icm_id,
      icm_name: "Work",
      mount_key: "work",
      schedule_id: "s1",
      fingerprint: "fp1",
      slot: ~U[2026-07-30 09:00:00Z],
      trigger: "scheduled",
      coalesced_count: 1,
      generation: 1,
      run_id: "run-1",
      workspace_root: ctx.ws
    }
  end

  defp tmp(kind) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-command-run-#{kind}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end
end
