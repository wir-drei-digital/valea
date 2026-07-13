defmodule Valea.ICM.WatcherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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
    # Prepare mounts/a before subscriptions to avoid race with discovery events
    File.mkdir_p!(Path.join(ws.path, "mounts/a"))

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
      File.mkdir_p!(Path.join(ws.path, "mounts/a-#{i}"))
      File.write!(Path.join(ws.path, "mounts/a-#{i}/warm-#{i}.txt"), "warm")
    end)

    # Drain any remaining queued messages from warm-up to avoid false positives
    # when refute_received is called below
    drain_any()

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
        id: "6001e724-556c-4719-921e-3e552c09835c",
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

  # Aggressively drain any remaining PubSub messages with a longer timeout
  defp drain_any do
    receive do
      {:icm_changed} -> drain_any()
      {:mounts_changed} -> drain_any()
      {:queue_changed} -> drain_any()
    after
      500 -> :ok
    end
  end

  test "removing a whole mounts/<name> dir broadcasts mounts_changed and icm_changed", %{ws: ws} do
    dir = Path.join(ws.path, "mounts/gone")
    File.mkdir_p!(dir)

    Manifest.write!(dir, %{
      id: "b22c7b72-133e-4b3b-b958-91462d555449",
      name: "Gone",
      description: ""
    })

    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

    # Warm up: prove the watcher is actually delivering events for this
    # workspace before relying on a one-shot (non-retriable) delete below —
    # unlike a create, a single rm_rf can't just be "tried again" on retry.
    poll_until_both(fn i ->
      warm_dir = Path.join(ws.path, "mounts/warm-#{i}")
      File.mkdir_p!(warm_dir)

      Manifest.write!(warm_dir, %{
        id: "52a89977-72dd-4823-ba21-3e0191e98fd7",
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

  # -- A2-T5: external mount roots + config/workspace.yaml -----------------

  # Mirrors `ValeaWeb.MountsRpcTest`/`Valea.Agents.SessionReadRootsTest`'s
  # helper of the same name/shape: declares an external (`kind: "path"`)
  # mount directly on disk, preserving `version`/`id` and every existing
  # mount entry — a "hand edit" that bypasses the RPC layer entirely (the
  # declare/undeclare RPC is a later task).
  defp declare_external!(ws_path, name, ref) do
    config_path = Path.join(ws_path, "config/workspace.yaml")
    {:ok, doc} = YamlElixir.read_from_file(config_path)

    mounts =
      (Map.get(doc, "mounts") || %{})
      |> Map.put(name, %{"kind" => "path", "ref" => ref})

    header = for key <- ["version", "id"], Map.has_key?(doc, key), do: "#{key}: #{doc[key]}"

    entries =
      Enum.flat_map(Enum.sort_by(mounts, &elem(&1, 0)), fn {n, entry} ->
        [
          "  #{n}:"
          | Enum.map(Enum.sort_by(entry, &elem(&1, 0)), fn {k, v} ->
              "    #{k}: #{render_scalar(v)}"
            end)
        ]
      end)

    File.write!(config_path, Enum.join(header ++ ["mounts:"] ++ entries, "\n") <> "\n")
  end

  defp render_scalar(v) when is_binary(v), do: inspect(v)
  defp render_scalar(v), do: to_string(v)

  defp external_icm!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-watcher-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    Manifest.write!(dir, %{
      id: "41d871cd-aadc-466f-a951-a5c47e197d47",
      name: name,
      description: ""
    })

    dir
  end

  defp poll_until_mounts_changed(trigger, attempts_left \\ 10)

  defp poll_until_mounts_changed(_trigger, 0) do
    flunk("mounts_changed was never broadcast after repeated fs writes")
  end

  defp poll_until_mounts_changed(trigger, attempts_left) do
    trigger.(attempts_left)

    receive do
      {:mounts_changed} -> :ok
    after
      300 -> poll_until_mounts_changed(trigger, attempts_left - 1)
    end
  end

  test "a write under an enabled external mount's root broadcasts icm_changed, not mounts_changed",
       %{ws: ws} do
    ext = external_icm!("Ext")

    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

    # Declaring the mount is itself discovery-relevant (a
    # config/workspace.yaml write) — drive it through `poll_until_both` so
    # its broadcasts are fully drained here, not left to race the
    # content-only assertion below.
    poll_until_both(fn _i -> declare_external!(ws.path, "ext", ext) end)
    drain_any()

    poll_until_broadcast(fn i ->
      File.write!(Path.join(ext, "note-#{i}.md"), "# note")
    end)

    refute_received {:mounts_changed}
  end

  test "touching an enabled external mount's icm.yaml broadcasts both icm_changed and mounts_changed",
       %{ws: ws} do
    ext = external_icm!("Ext")

    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

    poll_until_both(fn _i -> declare_external!(ws.path, "ext", ext) end)
    drain_any()

    poll_until_both(fn _i ->
      Manifest.write!(ext, %{
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        name: "Ext",
        description: "updated"
      })
    end)
  end

  test "after disabling an external mount, changes under its former root no longer broadcast icm_changed",
       %{ws: ws} do
    ext = external_icm!("Ext")

    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")
    Phoenix.PubSub.subscribe(Valea.PubSub, "queue")

    poll_until_both(fn _i -> declare_external!(ws.path, "ext", ext) end)
    drain_any()

    # Warm-up: prove the watcher is actively watching `ext` before relying
    # on its absence below.
    poll_until_broadcast(fn i -> File.write!(Path.join(ext, "warm-#{i}.md"), "warm") end)

    # Disabling via `Mounts.set_enabled/2` directly (not the RPC layer)
    # writes `config/workspace.yaml` — the ONLY reason this broadcasts at
    # all is this watcher's own config/ discovery handling.
    poll_until_mounts_changed(fn _i -> Valea.Mounts.set_enabled("ext", false) end)
    drain_any()

    File.write!(Path.join(ext, "post-disable.md"), "nope")

    # No positive event to wait on for the (correctly) suppressed write
    # above — use an unrelated queue/ broadcast, which itself takes a full
    # debounce+retry cycle, as the time buffer, then assert absence.
    poll_until_queue_broadcast(fn i ->
      File.write!(Path.join(ws.path, "queue/pending/probe-#{i}.json"), "{}")
    end)

    refute_received {:icm_changed}
  end

  test "a missing external root does not crash the watcher on workspace open", %{ws: ws} do
    missing_ref =
      Path.join(System.tmp_dir!(), "valea-missing-ext-#{System.os_time(:nanosecond)}")

    declare_external!(ws.path, "gone", missing_ref)

    Manager.close()
    {:ok, _reopened} = Manager.open_path(ws.path)

    watcher_pid = Process.whereis(Valea.ICM.Watcher)
    assert watcher_pid
    assert Process.alive?(watcher_pid)
  end

  test "hand-editing config/workspace.yaml to declare an external mount broadcasts mounts_changed and regenerates MOUNTS.md + settings on disk",
       %{ws: ws} do
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

    ext = external_icm!("Ext")

    poll_until_mounts_changed(fn _i -> declare_external!(ws.path, "ext", ext) end)

    %{root: ext_root} = ws.path |> Valea.Mounts.enabled() |> Enum.find(&(&1.name == "ext"))

    mounts_md = File.read!(Path.join(ws.path, "MOUNTS.md"))
    assert mounts_md =~ "@#{ext_root}/AGENTS.md"

    allow =
      ws.path
      |> Path.join(".claude/settings.json")
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["permissions", "allow"])

    assert "Read(#{ext_root}/**)" in allow
  end

  test "a mounts_changed broadcast that doesn't change the external-root set restarts neither listener",
       %{ws: _ws} do
    before_state = :sys.get_state(Valea.ICM.Watcher)

    Phoenix.PubSub.broadcast(Valea.PubSub, "mounts", {:mounts_changed})

    # No positive event to poll for here (a no-op recompute produces no
    # broadcast) — the recompute is debounced 200ms, so a bounded sleep
    # comfortably past that window is the only way to assert the negative
    # (pid stability), mirroring `drain_any/0`'s own fixed-timeout idiom
    # above.
    Process.sleep(300)

    after_state = :sys.get_state(Valea.ICM.Watcher)
    assert after_state.fixed_watcher == before_state.fixed_watcher
    assert after_state.external_watcher == before_state.external_watcher
  end

  test "recomputing a CHANGED external-root set restarts only the external listener — the fixed listener pid is stable",
       %{ws: ws} do
    # A fresh workspace has no external mounts, so no dynamic listener yet.
    %{fixed_watcher: fixed_before, external_watcher: nil} = :sys.get_state(Valea.ICM.Watcher)

    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

    ext = external_icm!("Ext")
    poll_until_mounts_changed(fn _i -> declare_external!(ws.path, "ext", ext) end)

    # `:sys.get_state/1` serializes behind the flush that broadcast, and the
    # recompute runs synchronously inside that same handle_info — so the
    # state observed here is already post-recompute.
    state = :sys.get_state(Valea.ICM.Watcher)
    assert state.fixed_watcher == fixed_before
    assert is_pid(state.external_watcher)

    drain_any()

    poll_until_mounts_changed(fn _i -> Valea.Mounts.set_enabled("ext", false) end)

    state = :sys.get_state(Valea.ICM.Watcher)
    assert state.fixed_watcher == fixed_before
    assert state.external_watcher == nil
  end

  test "a regeneration failure (unwritable workspace root) is rescued -- the watcher stays alive and still broadcasts",
       %{ws: ws} do
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

    # `config/workspace.yaml` lives in a SUBdirectory, whose own
    # permissions are untouched, so the discovery write itself still
    # succeeds; only writing `MOUNTS.md` (directly in `ws.path`) fails,
    # exercising `regenerate_workspace_metadata/1`'s rescue for real
    # instead of just by reasoning. Restored in an `on_exit` registered
    # here, which — LIFO — runs BEFORE the outer `setup` block's
    # `Manager.close/0` + `File.rm_rf!/1`.
    File.chmod!(ws.path, 0o500)
    on_exit(fn -> File.chmod!(ws.path, 0o700) end)

    log =
      capture_log(fn ->
        poll_until_mounts_changed(fn _i -> Valea.Mounts.set_enabled("w", false) end)
      end)

    assert log =~ "Valea.ICM.Watcher: workspace metadata regeneration failed"

    watcher_pid = Process.whereis(Valea.ICM.Watcher)
    assert watcher_pid
    assert Process.alive?(watcher_pid)
  end
end
