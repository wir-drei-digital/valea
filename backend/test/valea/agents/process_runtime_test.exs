defmodule Valea.Agents.ProcessRuntimeTest do
  use ExUnit.Case, async: false

  alias Valea.Agents.ProcessRuntime
  alias Valea.PlatformFixtures

  # These run against the FACADE, never against an adapter directly — green
  # here is what proves the Task 6 split is transparent: on unix the boot
  # selection lands on `Exec` (today's erlexec code, byte-identical), on
  # windows on `PortShim` + the real `valea-spawn` shim. Same assertions
  # either way, which is the whole point of the behaviour.
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-runtime-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, stderr_path: Path.join(dir, "runtime.stderr.log")}
  end

  defp spec(dir, cmd, args, stderr_path) do
    %{cmd: cmd, args: args, env: %{}, cd: dir, stderr_path: stderr_path}
  end

  # -- adapter selection (spec B1) ------------------------------------------

  defmodule FakeAdapter do
    @behaviour Valea.Agents.ProcessAdapter

    @impl true
    def start(_spec, _owner), do: {:ok, %{fake: true}}

    @impl true
    def write(_handle, _data), do: :ok

    @impl true
    def stop(_handle), do: :ok
  end

  test "facade routes through the boot-selected adapter (app-env seam)" do
    Application.put_env(:valea, :process_adapter, FakeAdapter)
    on_exit(fn -> ProcessRuntime.select_adapter!() end)

    assert {:ok, %{fake: true}} = ProcessRuntime.start(%{cmd: "x", args: []}, self())
    assert :ok = ProcessRuntime.write(%{fake: true}, "x")
    assert :ok = ProcessRuntime.stop(%{fake: true})
  end

  test "boot selection matches the host platform" do
    ProcessRuntime.select_adapter!()

    expected =
      case :os.type() do
        {:win32, _} -> ProcessRuntime.PortShim
        _ -> ProcessRuntime.Exec
      end

    assert ProcessRuntime.adapter() == expected
  end

  test "Exec's A1 assertion names the failure when :exec is unavailable" do
    assert_raise RuntimeError, ~r/erlexec unavailable.*spec A1/, fn ->
      ProcessRuntime.Exec.ensure_available!(false)
    end
  end

  # -- the relay contract, through the facade -------------------------------

  test "spawns with pipes, echoes stdin to owner as runtime_output, exits", %{
    dir: dir,
    stderr_path: stderr_path
  } do
    # A stdin->stdout copy: `cat` on unix, `findstr "^"` (matches every line)
    # on windows.
    echo =
      PlatformFixtures.script!(dir, "echo-stdin", "exec cat\n", "@echo off\r\nfindstr \"^\"\r\n")

    {:ok, handle} = ProcessRuntime.start(spec(dir, echo, [], stderr_path), self())

    :ok = ProcessRuntime.write(handle, "hello\n")
    assert_receive {:runtime_output, out}, 5_000
    assert out =~ "hello"

    :ok = ProcessRuntime.stop(handle)
    assert_receive {:runtime_exit, _code}, 6_000
  end

  test "stderr arrives as a separate message, never mixed into stdout", %{
    dir: dir,
    stderr_path: stderr_path
  } do
    noisy =
      PlatformFixtures.script!(
        dir,
        "out-and-err",
        "echo out; echo err 1>&2; sleep 5\n",
        # Two windows details: stderr goes FIRST, because the assertion below
        # waits for stdout and only then asks for the stderr FILE's tail — so
        # the shim's pump has certainly flushed it by then; and the sleep is
        # `ping`, because `timeout` refuses to run when stdin is a pipe, which
        # it always is under the spawn shim.
        "@echo off\r\necho err 1>&2\r\necho out\r\nping -n 6 127.0.0.1 >nul\r\n"
      )

    {:ok, handle} = ProcessRuntime.start(spec(dir, noisy, [], stderr_path), self())

    assert_receive {:runtime_output, out}, 5_000
    assert out =~ "out"

    # On unix this streams live; on windows it is the stderr FILE's tail,
    # emitted once when the process exits (spec B2's documented platform
    # difference) — so `stop/1` comes first there and the message still
    # arrives before `:runtime_exit`.
    :ok = ProcessRuntime.stop(handle)
    assert_receive {:runtime_stderr, err}, 6_000
    assert err =~ "err"
    assert_receive {:runtime_exit, _}, 6_000
  end

  @tag :unix_only
  test "stop kills the whole process group (no orphaned children)", %{
    dir: dir,
    stderr_path: stderr_path
  } do
    sh = System.find_executable("sh")

    {:ok, handle} =
      ProcessRuntime.start(
        spec(dir, sh, ["-c", "sleep 300 & echo started; wait"], stderr_path),
        self()
      )

    assert_receive {:runtime_output, _}, 2_000
    os_pid = handle.os_pid
    :ok = ProcessRuntime.stop(handle)
    assert_receive {:runtime_exit, _}, 6_000
    # After group kill, no `sleep 300` child of the dead shell survives.
    Process.sleep(200)
    {out, _} = System.cmd("pgrep", ["-g", to_string(os_pid)], stderr_to_stdout: true)
    assert out == ""
  end

  # The windows twin of the group-kill assertion: the shim's Job Object is
  # what makes it true there (spec B2), and `tasklist` is the only way to ask.
  # `start /b` detaches the grandchild from the .cmd's own console, so a
  # surviving one would be a real orphan, not a bookkeeping artifact. The
  # sleeper is a COPY of ping.exe under a unique name, so `tasklist` can name
  # exactly this test's process — and `ping`, not `timeout`, because `timeout`
  # refuses to run at all when stdin is a pipe.
  @tag :windows_only
  test "stop kills the whole tree (no orphaned grandchildren)", %{
    dir: dir,
    stderr_path: stderr_path
  } do
    marker = "valea-orphan-#{System.unique_integer([:positive])}.exe"
    sleeper = Path.join(dir, marker)
    File.cp!(System.find_executable("ping.exe"), sleeper)

    tree =
      PlatformFixtures.script!(
        dir,
        "spawn-tree",
        "true\n",
        "@echo off\r\nstart /b \"\" \"#{sleeper}\" -n 300 127.0.0.1 >nul\r\necho started\r\n" <>
          "ping -n 300 127.0.0.1 >nul\r\n"
      )

    {:ok, handle} = ProcessRuntime.start(spec(dir, tree, [], stderr_path), self())

    assert_receive {:runtime_output, _}, 5_000
    :ok = ProcessRuntime.stop(handle)
    assert_receive {:runtime_exit, _}, 6_000

    Process.sleep(500)
    {out, _} = System.cmd("tasklist", ["/fi", "imagename eq #{marker}"], stderr_to_stdout: true)
    refute out =~ marker
  end

  test "missing executable returns error, does not raise", %{
    dir: dir,
    stderr_path: stderr_path
  } do
    assert {:error, _} =
             ProcessRuntime.start(
               spec(dir, Path.join(dir, "nonexistent-bin"), [], stderr_path),
               self()
             )
  end
end
