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

  test "mail status change pushes mail_status with string keys" do
    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "mail",
      {:mail_status_changed,
       %{
         configured: true,
         credential: "present",
         state: "idle",
         last_sync_at: nil,
         last_error: nil,
         account: "Mara's mail",
         username: "mara@example.com",
         workspace_id: "ws-1"
       }}
    )

    assert_push "mail_status", %{
      "configured" => true,
      "credential" => "present",
      "state" => "idle",
      "account" => "Mara's mail",
      "username" => "mara@example.com",
      "workspace_id" => "ws-1"
    }
  end

  test "a sync pass start/finish pushes mail_sync with phase + newMessages" do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mail", {:mail_sync_started})
    assert_push "mail_sync", %{"phase" => "started", "newMessages" => 0}

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "mail",
      {:mail_sync_finished, %{new_messages: 3, errors: []}}
    )

    assert_push "mail_sync", %{"phase" => "finished", "newMessages" => 3}
  end

  test "a newly indexed message pushes mail_message with its path" do
    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "mail",
      {:mail_message_upserted, %{path: "sources/mail/messages/x.md"}}
    )

    assert_push "mail_message", %{"path" => "sources/mail/messages/x.md"}
  end

  test "a mailbox op finishing pushes mailbox_ops with the run id" do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mail_ops", {:mailbox_ops_updated, "run-1"})
    assert_push "mailbox_ops", %{"runId" => "run-1"}
  end

  test "a mailbox op becoming pending is NOT pushed (internal Engine trigger only)" do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mail_ops", {:mailbox_ops_pending, "run-1"})
    refute_push "mailbox_ops", %{}
    refute_push _, _
  end
end
