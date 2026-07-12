defmodule Valea.ICM.WatcherTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts.Manifest
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

  test "a write under mounts/<name>/... broadcasts icm_changed, but not mounts_changed", %{
    ws: ws
  } do
    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

    # The mount itself must already exist before the content-only write
    # below: creating the top-level `mounts/a` entry is itself
    # discovery-relevant (tested separately). Drive it through the same
    # subscription so `poll_until_both` fully DRAINS its broadcasts here —
    # not just fires them unobserved — which is what guarantees the
    # `refute_received` below can't race a still-in-flight mounts_changed
    # from this setup step.
    poll_until_both(fn i ->
      File.mkdir_p!(Path.join(ws.path, "mounts/a"))
      File.write!(Path.join(ws.path, "mounts/a/warm-#{i}.txt"), "warm")
    end)

    # macOS fsevents arms its native listener port asynchronously after
    # FileSystem.start_link/subscribe return, so an fs event fired
    # immediately after workspace creation can be missed while the port is
    # still spinning up. Retry the triggering write until the debounced
    # broadcast lands, instead of padding assert_receive's timeout.
    poll_until_broadcast(fn i ->
      File.mkdir_p!(Path.join(ws.path, "mounts/a/Offers"))
      File.write!(Path.join(ws.path, "mounts/a/Offers/X-#{i}.md"), "# X")
    end)

    # A page write is content-only — it must not also look like the mount
    # SET changed (no top-level mounts/<name> entry, no icm.yaml touched).
    refute_received {:mounts_changed}
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

  test "adding mounts/<name>/icm.yaml broadcasts both icm_changed and mounts_changed", %{ws: ws} do
    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

    poll_until_both(fn i ->
      mount_dir = Path.join(ws.path, "mounts/b-#{i}")
      File.mkdir_p!(mount_dir)

      Manifest.write!(mount_dir, %{
        id: "id-b",
        name: "B",
        description: ""
      })
    end)
  end

  # Needs to observe TWO independent broadcast types landing (not just
  # one), so it gets a larger retry budget than the single-event helpers
  # above/below — same 300ms-per-attempt polling discipline, just more of
  # them.
  defp poll_until_both(trigger, attempts_left \\ 20, seen \\ MapSet.new())

  defp poll_until_both(_trigger, 0, seen) do
    flunk(
      "expected both icm_changed and mounts_changed broadcasts; only saw #{inspect(MapSet.to_list(seen))}"
    )
  end

  defp poll_until_both(trigger, attempts_left, seen) do
    if MapSet.size(seen) == 2 do
      :ok
    else
      trigger.(attempts_left)
      seen = drain_known(seen)

      if MapSet.size(seen) == 2 do
        :ok
      else
        poll_until_both(trigger, attempts_left - 1, seen)
      end
    end
  end

  defp drain_known(seen) do
    receive do
      {:icm_changed} -> drain_known(MapSet.put(seen, :icm_changed))
      {:mounts_changed} -> drain_known(MapSet.put(seen, :mounts_changed))
    after
      300 -> seen
    end
  end

  test "removing a whole mounts/<name> dir broadcasts mounts_changed and icm_changed", %{ws: ws} do
    dir = Path.join(ws.path, "mounts/gone")
    File.mkdir_p!(dir)
    Manifest.write!(dir, %{id: "id-gone", name: "Gone", description: ""})

    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

    # Warm up: prove the watcher is actually delivering events for this
    # workspace before relying on a one-shot (non-retriable) delete below —
    # unlike a create, a single rm_rf can't just be "tried again" on retry.
    poll_until_both(fn i ->
      warm_dir = Path.join(ws.path, "mounts/warm-#{i}")
      File.mkdir_p!(warm_dir)

      Manifest.write!(warm_dir, %{
        id: "id-warm",
        name: "Warm",
        description: ""
      })
    end)

    File.rm_rf!(dir)

    assert_receive {:icm_changed}, 2000
    assert_receive {:mounts_changed}, 2000
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

  test "a mounts/ burst never broadcasts queue_changed (separate debounce timers)", %{ws: ws} do
    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "queue")

    poll_until_broadcast(fn i ->
      File.mkdir_p!(Path.join(ws.path, "mounts/a/Offers"))
      File.write!(Path.join(ws.path, "mounts/a/Offers/Iso-#{i}.md"), "# Iso")
    end)

    refute_received {:queue_changed}
  end

  test "a queue/ burst never broadcasts icm_changed or mounts_changed (separate debounce timers)",
       %{ws: ws} do
    Phoenix.PubSub.subscribe(Valea.PubSub, "queue")
    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

    poll_until_queue_broadcast(fn i ->
      File.write!(Path.join(ws.path, "queue/pending/iso-#{i}.json"), "{}")
    end)

    refute_received {:icm_changed}
    refute_received {:mounts_changed}
  end

  test "watcher dies with the workspace", %{ws: _ws} do
    Manager.close()
    refute Process.whereis(Valea.ICM.Watcher)
  end
end
