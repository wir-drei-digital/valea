defmodule ValeaWeb.WorkspaceEventsTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint ValeaWeb.Endpoint

  alias Valea.ICM.Watcher
  alias Valea.Mounts.Manifest
  alias Valea.Paths
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

    %{socket: socket}
  end

  test "workspace open pushes workspace event", %{socket: _socket} do
    {:ok, _} = Manager.create("W")
    assert_push "workspace", %{"open" => true, "name" => "W"}
  end

  test "icm change pushes icm_changed", %{socket: _socket} do
    {:ok, ws} = Manager.create("W")

    # Since Task 8.1 the watcher watches every enabled ICM's own
    # by-reference root (`Valea.Mounts.enabled/1`), not a workspace-local
    # `mounts/` tree — declare one (bypassing the RPC layer, mirroring
    # `Valea.ICM.WatcherTest`'s `declare_external!/3`) and wait for the
    # live `Valea.ICM.Watcher` to pick it up via its own public
    # `watched_roots/0`, so the discovery push this settling step also
    # produces can't be mistaken for the content-write push asserted below.
    ext = external_icm!()
    declare_external!(ws.path, "ext", ext)
    wait_until_watched!(ext)

    # macOS fsevents arms its native listener port asynchronously after
    # FileSystem.start_link/subscribe return (see
    # test/valea/icm/watcher_test.exs), so a bare write + assert_push can
    # miss the event while the port is still spinning up. Retry the
    # triggering write until the push lands, instead of padding
    # assert_push's timeout.
    poll_until_pushed(fn i ->
      File.write!(Path.join(ext, "fresh-#{i}.md"), "# fresh")
    end)
  end

  defp external_icm! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-events-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    Manifest.write!(dir, %{id: Ecto.UUID.generate(), name: "Ext", description: ""})

    dir
  end

  # Mirrors `Valea.ICM.WatcherTest`'s helper of the same name/shape: hand-
  # edits `config/workspace.yaml` to declare an ICM, bypassing the RPC
  # layer entirely.
  defp declare_external!(ws_path, name, ref) do
    config_path = Path.join(ws_path, "config/workspace.yaml")
    {:ok, doc} = YamlElixir.read_from_file(config_path)
    icms = (Map.get(doc, "icms") || %{}) |> Map.put(name, %{"path" => ref})
    header = for key <- ["version", "id"], Map.has_key?(doc, key), do: "#{key}: #{doc[key]}"

    entries = [
      "  #{name}:",
      "    path: #{inspect(ref)}"
    ]

    File.write!(config_path, Enum.join(header ++ ["icms:"] ++ entries, "\n") <> "\n")
    icms
  end

  defp wait_until_watched!(root, attempts_left \\ 40)

  defp wait_until_watched!(_root, 0) do
    flunk("ICM root was never picked up by the live watcher")
  end

  defp wait_until_watched!(root, attempts_left) do
    resolved =
      case Paths.resolve_real(".", root) do
        {:ok, r} -> r
        {:error, _} -> root
      end

    if resolved in Watcher.watched_roots() do
      :ok
    else
      Process.sleep(50)
      wait_until_watched!(root, attempts_left - 1)
    end
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

  test "a mounts change pushes mounts_changed" do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mounts", {:mounts_changed})
    assert_push "mounts_changed", %{}
  end

  test "queue change pushes queue_changed" do
    {:ok, ws} = Manager.create("W")

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
