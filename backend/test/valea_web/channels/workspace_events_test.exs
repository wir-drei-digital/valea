defmodule ValeaWeb.WorkspaceEventsTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint ValeaWeb.Endpoint

  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    {:ok, _, socket} =
      socket(ValeaWeb.UserSocket, nil, %{})
      |> subscribe_and_join(ValeaWeb.WorkspaceEventsChannel, "workspace:events")

    %{socket: socket, parent: Path.join(dir, "workspaces")}
  end

  test "workspace open pushes workspace event", %{parent: parent} do
    {:ok, _} = Manager.create(parent, "W")
    assert_push "workspace", %{"open" => true, "name" => "W"}
  end

  test "icm change pushes icm_changed", %{parent: parent} do
    {:ok, ws} = Manager.create(parent, "W")

    # macOS fsevents arms its native listener port asynchronously after
    # FileSystem.start_link/subscribe return (see
    # test/valea/icm/watcher_test.exs), so a bare mkdir + assert_push can miss
    # the event while the port is still spinning up. Retry the triggering
    # write until the push lands, instead of padding assert_push's timeout.
    poll_until_pushed(fn i ->
      File.mkdir_p!(Path.join(ws.path, "icm/Fresh #{i}"))
    end)
  end

  defp poll_until_pushed(trigger, attempts_left \\ 10)

  defp poll_until_pushed(_trigger, 0) do
    flunk("icm_changed was never pushed after repeated fs writes")
  end

  defp poll_until_pushed(trigger, attempts_left) do
    trigger.(attempts_left)

    try do
      assert_push "icm_changed", %{}, 300
    rescue
      ExUnit.AssertionError -> poll_until_pushed(trigger, attempts_left - 1)
    end
  end

  test "queue change pushes queue_changed", %{parent: parent} do
    {:ok, ws} = Manager.create(parent, "W")

    poll_until_queue_pushed(fn i ->
      File.write!(Path.join(ws.path, "queue/pending/probe-#{i}.json"), "{}")
    end)
  end

  defp poll_until_queue_pushed(trigger, attempts_left \\ 10)

  defp poll_until_queue_pushed(_trigger, 0) do
    flunk("queue_changed was never pushed after repeated fs writes")
  end

  defp poll_until_queue_pushed(trigger, attempts_left) do
    trigger.(attempts_left)

    try do
      assert_push "queue_changed", %{}, 300
    rescue
      ExUnit.AssertionError -> poll_until_queue_pushed(trigger, attempts_left - 1)
    end
  end
end
