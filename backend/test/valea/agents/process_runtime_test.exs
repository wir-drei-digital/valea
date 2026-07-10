defmodule Valea.Agents.ProcessRuntimeTest do
  use ExUnit.Case, async: false

  alias Valea.Agents.ProcessRuntime

  @cat System.find_executable("cat")

  test "spawns with pipes, echoes stdin to owner as runtime_output, exits" do
    {:ok, handle} =
      ProcessRuntime.start(%{cmd: @cat, args: [], env: %{}, cd: System.tmp_dir!()}, self())

    :ok = ProcessRuntime.write(handle, "hello\n")
    assert_receive {:runtime_output, "hello\n"}, 2_000

    :ok = ProcessRuntime.stop(handle)
    assert_receive {:runtime_exit, _code}, 6_000
  end

  test "stderr arrives as a separate message, never mixed into stdout" do
    sh = System.find_executable("sh")

    {:ok, handle} =
      ProcessRuntime.start(
        %{
          cmd: sh,
          args: ["-c", "echo out; echo err 1>&2; sleep 5"],
          env: %{},
          cd: System.tmp_dir!()
        },
        self()
      )

    assert_receive {:runtime_output, out}, 2_000
    assert out =~ "out"
    assert_receive {:runtime_stderr, err}, 2_000
    assert err =~ "err"
    :ok = ProcessRuntime.stop(handle)
    assert_receive {:runtime_exit, _}, 6_000
  end

  test "stop kills the whole process group (no orphaned children)" do
    sh = System.find_executable("sh")

    {:ok, handle} =
      ProcessRuntime.start(
        %{
          cmd: sh,
          args: ["-c", "sleep 300 & echo started; wait"],
          env: %{},
          cd: System.tmp_dir!()
        },
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

  test "missing executable returns error, does not raise" do
    assert {:error, _} =
             ProcessRuntime.start(
               %{cmd: "/nonexistent/bin", args: [], env: %{}, cd: "/tmp"},
               self()
             )
  end
end
