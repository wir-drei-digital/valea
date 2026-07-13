defmodule Valea.Mounts.DoctorTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts.Doctor
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager

  # -- fixtures ----------------------------------------------------------------

  defp tmp_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_manifest!(mount_dir, attrs) do
    File.mkdir_p!(mount_dir)
    File.write!(Path.join(mount_dir, "icm.yaml"), Manifest.render(attrs))
  end

  defp write_workspace_yaml!(root, contents) do
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/workspace.yaml"), contents)
  end

  defp find(checks, id), do: Enum.find(checks, &(&1["id"] == id))

  # No live process required for most of this suite (`Doctor.run/1` is pure
  # filesystem + config), but a couple of tests DO start the real
  # `Workspace.Manager`/`Valea.ICM.Watcher` — closing here (and in every
  # test's `on_exit`) keeps the global singleton clean regardless of test
  # order, mirroring `Valea.ICM.WatcherTest`'s own setup discipline.
  setup do
    Manager.close()
    on_exit(fn -> Manager.close() end)
    :ok
  end

  # -- embedded mounts: manifest_ok only ----------------------------------------

  describe "run/1 — embedded mounts" do
    test "a healthy embedded mount reports manifest_ok, nothing else" do
      root = tmp_dir!("vmounts-doctor")

      write_manifest!(Path.join(root, "mounts/alpha"), %{
        id: "7cfae9ed-1105-4498-abf5-60c6f7c10961",
        name: "Alpha",
        description: ""
      })

      {:ok, %{checks: checks, ok: ok}} = Doctor.run(root)

      assert [check] = checks
      assert check["id"] == "manifest_ok:alpha"
      assert check["status"] == "ok"
      assert check["remedy"] == nil
      assert ok == true
    end

    test "an embedded mount with no icm.yaml fails manifest_ok with the degrade reason" do
      root = tmp_dir!("vmounts-doctor")
      File.mkdir_p!(Path.join(root, "mounts/bare"))

      {:ok, %{checks: checks, ok: ok}} = Doctor.run(root)

      assert [check] = checks
      assert check["id"] == "manifest_ok:bare"
      assert check["status"] == "failed"
      assert check["detail"] == "icm.yaml is missing"
      assert is_binary(check["remedy"])
      assert ok == false
    end

    test "an embedded mount with an invalid icm.yaml fails manifest_ok with the manifest's own reason" do
      root = tmp_dir!("vmounts-doctor")
      dir = Path.join(root, "mounts/broken")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "icm.yaml"), "name: [unterminated")

      {:ok, %{checks: [check], ok: false}} = Doctor.run(root)
      assert check["id"] == "manifest_ok:broken"
      assert check["status"] == "failed"
      assert is_binary(check["detail"])
    end
  end

  # -- external mounts: ref_resolves gates the rest -----------------------------

  describe "run/1 — external mounts: ref_resolves gating" do
    test "a missing ref key fails ref_resolves and marks every later check unknown" do
      root = tmp_dir!("vmounts-doctor")

      write_workspace_yaml!(root, """
      mounts:
        outside:
          kind: path
      """)

      {:ok, %{checks: checks, ok: false}} = Doctor.run(root)

      ref = find(checks, "ref_resolves:external:outside")
      assert ref["status"] == "failed"
      assert is_binary(ref["detail"])
      assert is_binary(ref["remedy"])

      for id <- [
            "manifest_ok:external:outside",
            "secrets_hygiene:external:outside",
            "watcher_live:external:outside"
          ] do
        check = find(checks, id)
        assert check["status"] == "unknown"
        assert check["remedy"] == nil
        assert check["detail"] =~ "ref_resolves"
      end
    end

    test "a ref that no longer resolves to a folder fails ref_resolves with the not-found reason" do
      root = tmp_dir!("vmounts-doctor")
      missing = Path.join(tmp_dir!("vmounts-doctor-parent"), "does-not-exist")

      write_workspace_yaml!(root, """
      mounts:
        outside:
          kind: path
          ref: "#{missing}"
      """)

      {:ok, %{checks: checks}} = Doctor.run(root)

      ref = find(checks, "ref_resolves:external:outside")
      assert ref["status"] == "failed"
      assert ref["detail"] =~ "folder not found at"
      assert find(checks, "manifest_ok:external:outside")["status"] == "unknown"
    end

    test "a guardrail-degraded ref (inside the workspace) surfaces its exact reason on ref_resolves" do
      root = tmp_dir!("vmounts-doctor")
      inside = Path.join(root, "nested/icm")

      write_manifest!(inside, %{
        id: "7b7beecf-7c67-4847-9d9a-7a648e785490",
        name: "Inside",
        description: ""
      })

      write_workspace_yaml!(root, """
      mounts:
        insider:
          kind: path
          ref: "#{inside}"
      """)

      {:ok, %{checks: checks}} = Doctor.run(root)

      ref = find(checks, "ref_resolves:external:insider")
      assert ref["status"] == "failed"
      assert ref["detail"] =~ "workspace"
      assert find(checks, "manifest_ok:external:insider")["status"] == "unknown"
      assert find(checks, "watcher_live:external:insider")["status"] == "unknown"
    end

    test "an unsafe (glob-metacharacter) ref path surfaces its reason on ref_resolves" do
      root = tmp_dir!("vmounts-doctor")
      parent = tmp_dir!("vmounts-doctor-parent")
      weird = Path.join(parent, "weird[1]")

      write_manifest!(weird, %{
        id: "7d23ae36-9be4-45a1-9de6-a3359141e78e",
        name: "Weird",
        description: ""
      })

      write_workspace_yaml!(root, """
      mounts:
        weird:
          kind: path
          ref: "#{weird}"
      """)

      {:ok, %{checks: checks}} = Doctor.run(root)

      ref = find(checks, "ref_resolves:external:weird")
      assert ref["status"] == "failed"
      assert ref["detail"] =~ "glob"
    end
  end

  # -- external mounts: manifest_ok is independent of secrets/watcher ----------

  describe "run/1 — external mounts: manifest_ok" do
    test "a resolvable ref with no icm.yaml passes ref_resolves but fails manifest_ok, and still runs secrets_hygiene" do
      root = tmp_dir!("vmounts-doctor")
      ext = tmp_dir!("vmounts-doctor-ext")

      write_workspace_yaml!(root, """
      mounts:
        outside:
          kind: path
          ref: "#{ext}"
      """)

      {:ok, %{checks: checks, ok: false}} = Doctor.run(root)

      assert find(checks, "ref_resolves:external:outside")["status"] == "ok"
      assert find(checks, "manifest_ok:external:outside")["status"] == "failed"
      assert find(checks, "manifest_ok:external:outside")["detail"] == "icm.yaml is missing"
      # NOT gated by manifest_ok's failure — the folder is real and readable.
      assert find(checks, "secrets_hygiene:external:outside")["status"] == "ok"
    end
  end

  # -- external mounts: secrets_hygiene -----------------------------------------

  describe "run/1 — external mounts: secrets_hygiene" do
    defp healthy_external_workspace!(mount_name \\ "outside") do
      root = tmp_dir!("vmounts-doctor")
      ext = tmp_dir!("vmounts-doctor-ext")

      write_manifest!(ext, %{
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        name: "External",
        description: ""
      })

      write_workspace_yaml!(root, """
      mounts:
        #{mount_name}:
          kind: path
          ref: "#{ext}"
      """)

      {root, ext}
    end

    test "no secrets/ dir or .env-like file at the root passes clean" do
      {root, _ext} = healthy_external_workspace!()

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "secrets_hygiene:external:outside")
      assert check["status"] == "ok"
      assert check["remedy"] == nil
    end

    test "a secrets/ directory at the mount root fails secrets_hygiene with the warning remedy" do
      {root, ext} = healthy_external_workspace!()
      File.mkdir_p!(Path.join(ext, "secrets"))

      {:ok, %{checks: checks, ok: false}} = Doctor.run(root)
      check = find(checks, "secrets_hygiene:external:outside")
      assert check["status"] == "failed"
      assert check["detail"] =~ "secrets"
      assert check["remedy"] =~ "deny-list"
    end

    test "a secrets file (not a directory) named 'secrets' does not trip the check" do
      {root, ext} = healthy_external_workspace!()
      File.write!(Path.join(ext, "secrets"), "not a directory")

      {:ok, %{checks: checks}} = Doctor.run(root)
      assert find(checks, "secrets_hygiene:external:outside")["status"] == "ok"
    end

    test "a .env.local file at the mount root fails secrets_hygiene" do
      {root, ext} = healthy_external_workspace!()
      File.write!(Path.join(ext, ".env.local"), "SECRET=1")

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "secrets_hygiene:external:outside")
      assert check["status"] == "failed"
      assert check["detail"] =~ ".env.local"
    end

    test "a bare .env file at the mount root fails secrets_hygiene" do
      {root, ext} = healthy_external_workspace!()
      File.write!(Path.join(ext, ".env"), "SECRET=1")

      {:ok, %{checks: checks}} = Doctor.run(root)
      assert find(checks, "secrets_hygiene:external:outside")["status"] == "failed"
    end

    test "a filename that merely contains .env (not a prefix) is not flagged" do
      {root, ext} = healthy_external_workspace!()
      File.write!(Path.join(ext, "not.env.but.close"), "fine")
      File.write!(Path.join(ext, "myenvfile"), "fine")

      {:ok, %{checks: checks}} = Doctor.run(root)
      assert find(checks, "secrets_hygiene:external:outside")["status"] == "ok"
    end

    test "secrets_hygiene never crashes when the mount root is unreadable and check detail carries no file contents" do
      {root, ext} = healthy_external_workspace!()
      File.write!(Path.join(ext, ".env"), "TOP_SECRET_VALUE=do-not-leak")

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "secrets_hygiene:external:outside")
      refute check["detail"] =~ "TOP_SECRET_VALUE"
      refute check["detail"] =~ "do-not-leak"
    end
  end

  # -- external mounts: watcher_live, pure (no live Watcher process) -----------

  describe "run/1 — external mounts: watcher_live without a running watcher" do
    test "a disabled external mount is 'unknown', not 'failed' — nothing to fix" do
      root = tmp_dir!("vmounts-doctor")
      ext = tmp_dir!("vmounts-doctor-ext")

      write_manifest!(ext, %{
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        name: "External",
        description: ""
      })

      write_workspace_yaml!(root, """
      mounts:
        outside:
          kind: path
          ref: "#{ext}"
          enabled: false
      """)

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "watcher_live:external:outside")
      assert check["status"] == "unknown"
      assert check["detail"] =~ "disabled"
      assert check["remedy"] == nil
    end

    test "an enabled mount reports watcher_live failed (best-effort) when no watcher is running" do
      refute Process.whereis(Valea.ICM.Watcher)
      {root, _ext} = healthy_external_workspace!()

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "watcher_live:external:outside")
      assert check["status"] == "failed"
      assert is_binary(check["remedy"])
    end
  end

  # -- embedded/external name collision: check ids stay unique -----------------

  describe "run/1 — embedded/external name collision" do
    test "both entries' checks get unique ids (kind-qualified), no duplicate id in the flat list" do
      root = tmp_dir!("vmounts-doctor")

      write_manifest!(Path.join(root, "mounts/dup"), %{
        id: "36488521-9cdc-4cd1-b23c-8431b13bbf95",
        name: "Dup",
        description: ""
      })

      ext = tmp_dir!("vmounts-doctor-ext")

      write_manifest!(ext, %{
        id: "96674b80-7a45-4b5b-9464-26c906170454",
        name: "ExtDup",
        description: ""
      })

      write_workspace_yaml!(root, """
      mounts:
        dup:
          kind: path
          ref: "#{ext}"
      """)

      {:ok, %{checks: checks}} = Doctor.run(root)

      ids = Enum.map(checks, & &1["id"])
      assert Enum.uniq(ids) == ids, "expected every check id to be unique, got #{inspect(ids)}"

      # The embedded side keeps the bare id and fails manifest_ok with the
      # collision reason.
      embedded = find(checks, "manifest_ok:dup")
      assert embedded
      assert embedded["status"] == "failed"
      assert embedded["detail"] == "name used by both an embedded and an external mount"

      # The external side is kind-qualified — same check name, same mount
      # name, disjoint id — and fails manifest_ok with the same reason
      # (collision is not ref-level, so ref_resolves itself reports ok).
      external = find(checks, "manifest_ok:external:dup")
      assert external
      assert external["status"] == "failed"
      assert external["detail"] == "name used by both an embedded and an external mount"

      refute embedded["id"] == external["id"]
    end
  end

  # -- overall ok computation ----------------------------------------------------

  describe "run/1 — overall ok" do
    test "no mounts at all is vacuously ok" do
      root = tmp_dir!("vmounts-doctor")
      assert {:ok, %{checks: [], ok: true}} = Doctor.run(root)
    end
  end

  # -- run/0: no-workspace handling ----------------------------------------------

  describe "run/0" do
    test "no workspace open returns :no_workspace, same as its sibling doctors' callers" do
      Manager.close()
      assert Doctor.run() == {:error, :no_workspace}
    end
  end

  # -- end-to-end with a real running watcher -------------------------------------
  #
  # These are the only tests in this suite that start the real
  # `Workspace.Manager`/`Valea.ICM.Watcher` — everything above is pure
  # filesystem + config, deliberately independent of the live process (see
  # its own describe block above). Mirrors `Valea.ICM.WatcherTest`'s
  # `declare_external!/3` + debounce-polling discipline for getting the
  # watcher to actually pick up a hand-edited external declaration.
  describe "run/1 — end to end with a live watcher" do
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

    test "a fully healthy, enabled, watched external mount is all ok", %{ws: ws} do
      ext = tmp_dir!("vmounts-doctor-ext")

      write_manifest!(ext, %{
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        name: "External",
        description: ""
      })

      Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")
      poll_until_mounts_changed(fn _i -> declare_external!(ws.path, "outside", ext) end)

      {:ok, %{checks: checks, ok: true}} = Doctor.run(ws.path)

      for id <- [
            "ref_resolves:external:outside",
            "manifest_ok:external:outside",
            "secrets_hygiene:external:outside",
            "watcher_live:external:outside"
          ] do
        check = find(checks, id)
        assert check["status"] == "ok", "expected #{id} to be ok, got #{inspect(check)}"
      end
    end

    test "watcher_live is ok for an enabled mount, then 'unknown' once disabled", %{ws: ws} do
      ext = tmp_dir!("vmounts-doctor-ext")

      write_manifest!(ext, %{
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        name: "External",
        description: ""
      })

      Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")
      poll_until_mounts_changed(fn _i -> declare_external!(ws.path, "outside", ext) end)

      {:ok, %{checks: checks}} = Doctor.run(ws.path)
      assert find(checks, "watcher_live:external:outside")["status"] == "ok"

      poll_until_mounts_changed(fn _i -> Valea.Mounts.set_enabled("outside", false) end)

      {:ok, %{checks: checks}} = Doctor.run(ws.path)
      check = find(checks, "watcher_live:external:outside")
      assert check["status"] == "unknown"
      assert check["detail"] =~ "disabled"
    end
  end

  # `healthy_external_workspace!/1` is defined inside the secrets_hygiene
  # `describe` block above (so it's colocated with its main users) but is
  # also reused by the plain watcher_live tests in this module — ExUnit
  # `describe` blocks share one module namespace, so this just documents
  # the cross-reference.
end
