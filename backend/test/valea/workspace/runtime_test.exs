defmodule Valea.Workspace.RuntimeTest do
  use ExUnit.Case, async: false

  test "runtime supervises watcher + audit + session supervisor and dies as a unit" do
    root = Path.join(System.tmp_dir!(), "vrt-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(Path.join(root, "icm"))
    File.mkdir_p!(Path.join(root, "logs"))
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, sup} = Valea.Workspace.Runtime.start_link(%{root: root, generation: 1})
    assert Process.whereis(Valea.ICM.Watcher)
    assert Process.whereis(Valea.Audit)
    assert Process.whereis(Valea.Agents.SessionSupervisor)

    :ok = Supervisor.stop(sup)
    refute Process.whereis(Valea.ICM.Watcher)
    refute Process.whereis(Valea.Audit)
    refute Process.whereis(Valea.Agents.SessionSupervisor)
  end
end
