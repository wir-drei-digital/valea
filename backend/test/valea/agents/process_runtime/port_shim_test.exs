defmodule Valea.Agents.ProcessRuntime.PortShimTest do
  use ExUnit.Case, async: false

  alias Valea.Agents.ProcessRuntime.PortShim
  alias Valea.PlatformFixtures

  # PortShim is platform-neutral Port code — only its SELECTION is
  # Windows-bound (spec B1) — so it is driven here against a FAKE
  # `valea-spawn`: a script that keeps the contract this adapter depends on
  # (stdin/stdout passthrough, child stderr into $VALEA_SPAWN_STDERR_FILE,
  # exit codes). The real shim's own guarantees (Job Object tree kill, 1 MiB
  # cap, COMSPEC quoting) are proven by the Rust suite in desktop/src-tauri,
  # and on the Windows lane process_runtime_test.exs drives this adapter
  # through the facade against that real binary.
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-portshim-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    previous = System.get_env("VALEA_SPAWN_SHIM")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("VALEA_SPAWN_SHIM")
        value -> System.put_env("VALEA_SPAWN_SHIM", value)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir, stderr_path: Path.join([dir, "logs", "agent.stderr.log"])}
  end

  # A stand-in for valea-spawn: `exec` the target with its stderr redirected
  # into the contract's file, so stdout/stdin/exit-code all pass through.
  defp fake_shim!(dir) do
    path =
      PlatformFixtures.script!(
        dir,
        "fake-shim",
        ~S"""
        exec "$@" 2>>"$VALEA_SPAWN_STDERR_FILE"
        """,
        "@echo off\r\n"
      )

    System.put_env("VALEA_SPAWN_SHIM", path)
    path
  end

  # The other half of the real shim's contract: EOF on ITS stdin means "the
  # Port closed, take the tree down". valea-spawn does that with a Job Object
  # and exits 120; a `sh` stand-in reads its stdin to EOF and kills the child.
  # Separate fixture from `fake_shim!/1` because sh cannot both FORWARD stdin
  # and watch it for EOF — the real shim has a pump thread per stream.
  defp teardown_shim!(dir) do
    path =
      PlatformFixtures.script!(
        dir,
        "teardown-shim",
        ~S"""
        "$@" 2>>"$VALEA_SPAWN_STDERR_FILE" 0</dev/null &
        child=$!
        cat >/dev/null
        kill -9 "$child" 2>/dev/null
        exit 120
        """,
        "@echo off\r\n"
      )

    System.put_env("VALEA_SPAWN_SHIM", path)
    path
  end

  # A shim that fails BEFORE spawning anything, the way valea-spawn's 64/65/66
  # do: the stderr file exists and is empty, no stdout, a shim-level code.
  defp failing_shim!(dir, code, extra_stdout \\ "") do
    path =
      PlatformFixtures.script!(
        dir,
        "fake-shim-#{code}-#{System.unique_integer([:positive])}",
        ~s"""
        : > "$VALEA_SPAWN_STDERR_FILE"
        #{extra_stdout}
        exit #{code}
        """,
        "@echo off\r\nexit /b #{code}\r\n"
      )

    System.put_env("VALEA_SPAWN_SHIM", path)
    path
  end

  defp spec(dir, cmd, args, overrides \\ %{}) do
    Map.merge(
      %{
        cmd: cmd,
        args: args,
        env: %{},
        cd: dir,
        stderr_path: Path.join([dir, "logs", "agent.stderr.log"])
      },
      overrides
    )
  end

  # -- start/2 refuses rather than half-starts ------------------------------

  test "no VALEA_SPAWN_SHIM -> fails fast, never a Port-only fallback", %{dir: dir} do
    System.delete_env("VALEA_SPAWN_SHIM")

    assert {:error, reason} = PortShim.start(spec(dir, "anything", []), self())
    assert reason =~ "spawn shim missing"
    assert reason =~ "windows spec B2"
  end

  test "VALEA_SPAWN_SHIM pointing nowhere -> named failure", %{dir: dir} do
    missing = Path.join(dir, "not-installed")
    System.put_env("VALEA_SPAWN_SHIM", missing)

    assert {:error, reason} = PortShim.start(spec(dir, "anything", []), self())
    assert reason =~ "spawn shim missing at #{missing}"
  end

  test "missing stderr_path -> refuses (a dropped stderr stream is an unexplainable hang)", %{
    dir: dir
  } do
    fake_shim!(dir)
    spec = spec(dir, "anything", []) |> Map.delete(:stderr_path)

    assert {:error, "stderr path missing (windows spec B2)"} = PortShim.start(spec, self())
  end

  test "missing executable -> the same error the unix adapter gives", %{dir: dir} do
    fake_shim!(dir)
    missing = Path.join(dir, "no-such-agent")

    assert {:error, "executable not found: " <> ^missing} =
             PortShim.start(spec(dir, missing, []), self())
  end

  test "a .cmd target with an unquotable argument is refused up front (shim exit 64)", %{
    dir: dir
  } do
    fake_shim!(dir)
    batch = Path.join(dir, "agent.cmd")
    File.write!(batch, "@echo off\r\n")

    assert {:error, reason} = PortShim.start(spec(dir, batch, ["--flag=\"x\""]), self())
    assert reason =~ "double quote"
  end

  # -- the relay contract, over a real Port ---------------------------------

  @tag :unix_only
  test "relays stdout, accepts stdin, and stop/1 closes the port", %{dir: dir} do
    fake_shim!(dir)
    echo = PlatformFixtures.script!(dir, "echo", "exec cat\n", "@echo off\r\nfindstr \"^\"\r\n")

    assert {:ok, handle} = PortShim.start(spec(dir, echo, []), self())
    assert is_integer(handle.os_pid)
    assert is_pid(handle.relay_pid)

    :ok = PortShim.write(handle, "hello\n")
    assert_receive {:runtime_output, "hello\n"}, 5_000

    :ok = PortShim.stop(handle)
    # nil, not 120: the port is gone before the shim's teardown code could be
    # reported, exactly like unix's signal kill.
    assert_receive {:runtime_exit, nil}, 5_000
  end

  @tag :unix_only
  test "the stderr FILE's tail arrives as one runtime_stderr before the exit", %{dir: dir} do
    fake_shim!(dir)

    noisy =
      PlatformFixtures.script!(
        dir,
        "noisy",
        "echo out; echo boom 1>&2; exit 3\n",
        "@echo off\r\necho out\r\necho boom 1>&2\r\nexit /b 3\r\n"
      )

    assert {:ok, _handle} = PortShim.start(spec(dir, noisy, []), self())

    assert_receive {:runtime_output, "out\n"}, 5_000
    assert_receive {:runtime_stderr, "boom\n"}, 5_000
    assert_receive {:runtime_exit, 3}, 5_000
  end

  @tag :unix_only
  test "the adapter creates the stderr file's directory and names it in the child env", %{
    dir: dir,
    stderr_path: stderr_path
  } do
    fake_shim!(dir)

    dump =
      PlatformFixtures.script!(
        dir,
        "dump-env",
        "echo \"$VALEA_SPAWN_STDERR_FILE|$AGENT_MARKER|$PWD\"\n",
        "@echo off\r\necho %VALEA_SPAWN_STDERR_FILE%|%AGENT_MARKER%|%CD%\r\n"
      )

    cwd = Path.join(dir, "workdir")
    File.mkdir_p!(cwd)

    refute File.dir?(Path.dirname(stderr_path))

    assert {:ok, _handle} =
             PortShim.start(
               spec(dir, dump, [], %{env: %{"AGENT_MARKER" => "seen"}, cd: cwd}),
               self()
             )

    assert_receive {:runtime_output, line}, 5_000
    assert line =~ stderr_path
    assert line =~ "seen"
    assert line =~ Path.basename(cwd)
    assert File.dir?(Path.dirname(stderr_path))
  end

  @tag :unix_only
  test "a shim-level exit with nothing produced is explained, not just relayed", %{dir: dir} do
    failing_shim!(dir, 66)

    assert {:ok, _handle} =
             PortShim.start(spec(dir, PlatformFixtures.host_executable!(), []), self())

    assert_receive {:runtime_stderr, explanation}, 5_000
    assert explanation =~ "valea-spawn exited 66"
    assert explanation =~ "could not be spawned"
    assert explanation =~ "No agent process was started"
    assert_receive {:runtime_exit, 66}, 5_000
  end

  @tag :unix_only
  test "an agent that produced output and exits 66 itself is NOT blamed on the shim", %{
    dir: dir
  } do
    failing_shim!(dir, 66, "echo working")

    assert {:ok, _handle} =
             PortShim.start(spec(dir, PlatformFixtures.host_executable!(), []), self())

    assert_receive {:runtime_output, "working\n"}, 5_000
    assert_receive {:runtime_exit, 66}, 5_000
    refute_received {:runtime_stderr, _}
  end

  @tag :unix_only
  test "the owner dying takes the subprocess with it (no orphan without terminate/2)", %{
    dir: dir
  } do
    teardown_shim!(dir)
    marker = "valea-portshim-orphan-#{System.unique_integer([:positive])}"
    on_exit(fn -> System.cmd("pkill", ["-9", "-f", marker], stderr_to_stdout: true) end)

    sleeper =
      PlatformFixtures.script!(
        dir,
        "sleeper",
        "exec -a \"#{marker}\" sleep 60\n",
        "@echo off\r\ntimeout /t 60 /nobreak >nul\r\n"
      )

    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, _handle} = PortShim.start(spec(dir, sleeper, []), self())
        send(test_pid, :started)
        Process.sleep(:infinity)
      end)

    # Kills the owner even if an assertion below fails, so no leaked owner
    # holds a Port over a directory this suite is about to delete.
    on_exit(fn -> Process.exit(owner, :kill) end)

    assert_receive :started, 5_000
    assert eventually(fn -> alive?(marker) end), "the sleeper never came up"

    Process.exit(owner, :kill)
    assert eventually(fn -> not alive?(marker) end), "the sleeper outlived its owner"
  end

  defp alive?(marker) do
    match?({_out, 0}, System.cmd("pgrep", ["-f", marker], stderr_to_stdout: true))
  end

  defp eventually(fun) do
    Enum.reduce_while(1..40, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end
end
