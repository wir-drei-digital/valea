defmodule Valea.ICM.WatcherTest do
  use ExUnit.Case, async: false

  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "W")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{ws: ws}
  end

  test "a new folder under icm/ broadcasts icm_changed", %{ws: ws} do
    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")

    # macOS fsevents arms its native listener port asynchronously after
    # FileSystem.start_link/subscribe return, so an fs event fired
    # immediately after workspace creation can be missed while the port is
    # still spinning up. Retry the triggering write until the debounced
    # broadcast lands, instead of padding assert_receive's timeout.
    poll_until_broadcast(fn i ->
      File.mkdir_p!(Path.join(ws.path, "icm/New Folder #{i}"))
    end)
  end

  defp poll_until_broadcast(trigger, attempts_left \\ 10)

  defp poll_until_broadcast(_trigger, 0) do
    flunk("icm_changed was never broadcast after repeated fs writes")
  end

  defp poll_until_broadcast(trigger, attempts_left) do
    trigger.(attempts_left)

    receive do
      {:icm_changed} -> :ok
    after
      300 -> poll_until_broadcast(trigger, attempts_left - 1)
    end
  end

  test "a new file under queue/pending broadcasts queue_changed", %{ws: ws} do
    Phoenix.PubSub.subscribe(Valea.PubSub, "queue")

    poll_until_queue_broadcast(fn i ->
      File.write!(Path.join(ws.path, "queue/pending/probe-#{i}.json"), "{}")
    end)
  end

  defp poll_until_queue_broadcast(trigger, attempts_left \\ 10)

  defp poll_until_queue_broadcast(_trigger, 0) do
    flunk("queue_changed was never broadcast after repeated fs writes")
  end

  defp poll_until_queue_broadcast(trigger, attempts_left) do
    trigger.(attempts_left)

    receive do
      {:queue_changed} -> :ok
    after
      300 -> poll_until_queue_broadcast(trigger, attempts_left - 1)
    end
  end

  test "watcher dies with the workspace", %{ws: _ws} do
    Manager.close()
    refute Process.whereis(Valea.ICM.Watcher)
  end
end
