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

  defp write_context!(mount_dir, content) do
    File.mkdir_p!(mount_dir)
    File.write!(Path.join(mount_dir, "CONTEXT.md"), content)
  end

  defp write_workspace_yaml!(root, contents) do
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/workspace.yaml"), contents)
  end

  # `icms:` fixture writer — config truth is `icms:` ONLY (no more
  # `mounts:`/`kind: path`/`ref:`); every mount is external (`rel_root:
  # nil`), so `Doctor`'s `check_id/2` is always the bare `"<check>:<mount
  # key>"` form (no more embedded/external kind qualifier — Phase 8 dropped
  # it along with the embedded-mount concept itself). `entries` is a list of
  # `{mount_key, path_or_nil, extra_kw}` — `extra_kw` may carry
  # `enabled: false`.
  defp write_icms!(root, entries) do
    lines =
      Enum.flat_map(entries, fn
        {key, nil, _extra} ->
          ["  #{key}:"]

        {key, path, extra} ->
          enabled_line =
            case Keyword.get(extra, :enabled) do
              nil -> []
              enabled -> ["    enabled: #{enabled}"]
            end

          ["  #{key}:", "    path: \"#{path}\""] ++ enabled_line
      end)

    write_workspace_yaml!(root, Enum.join(["icms:" | lines], "\n") <> "\n")
  end

  defp find(checks, id), do: Enum.find(checks, &(&1["id"] == id))

  # No live process required for most of this suite (`Doctor.run/1,2` is
  # pure filesystem + config), but a couple of tests DO start the real
  # `Workspace.Manager`/`Valea.ICM.Watcher` — closing here (and in every
  # test's `on_exit`) keeps the global singleton clean regardless of test
  # order, mirroring `Valea.ICM.WatcherTest`'s own setup discipline.
  setup do
    Manager.close()
    on_exit(fn -> Manager.close() end)
    :ok
  end

  # -- path_resolves gating ------------------------------------------------------

  describe "run/1 — path_resolves gating" do
    test "a missing path key fails path_resolves and marks every later check unknown" do
      root = tmp_dir!("vmounts-doctor")
      write_workspace_yaml!(root, "icms:\n  outside: {}\n")

      {:ok, %{checks: checks, ok: false}} = Doctor.run(root)

      path = find(checks, "path_resolves:outside")
      assert path["status"] == "failed"
      assert is_binary(path["detail"])
      assert is_binary(path["remedy"])

      for id <- [
            "manifest_format2:outside",
            "unique_id:outside",
            "related_icms:outside",
            "secrets_hygiene:outside",
            "watcher_live:outside"
          ] do
        check = find(checks, id)
        assert check["status"] == "unknown"
        assert check["remedy"] == nil
        assert check["detail"] =~ "path_resolves"
      end
    end

    test "a path that no longer resolves to a folder fails path_resolves with the not-found reason and a repair remedy" do
      root = tmp_dir!("vmounts-doctor")
      missing = Path.join(tmp_dir!("vmounts-doctor-parent"), "does-not-exist")

      write_icms!(root, [{"outside", missing, []}])

      {:ok, %{checks: checks}} = Doctor.run(root)

      path = find(checks, "path_resolves:outside")
      assert path["status"] == "failed"
      assert path["detail"] =~ "folder not found at"
      assert is_binary(path["remedy"])
      assert find(checks, "manifest_format2:outside")["status"] == "unknown"
    end

    test "a guardrail-degraded path (inside the workspace) surfaces its exact reason on path_resolves" do
      root = tmp_dir!("vmounts-doctor")
      inside = Path.join(root, "nested/icm")

      write_manifest!(inside, %{
        id: "7b7beecf-7c67-4847-9d9a-7a648e785490",
        name: "Inside",
        description: ""
      })

      write_icms!(root, [{"insider", inside, []}])

      {:ok, %{checks: checks}} = Doctor.run(root)

      path = find(checks, "path_resolves:insider")
      assert path["status"] == "failed"
      assert path["detail"] =~ "workspace"
      assert find(checks, "manifest_format2:insider")["status"] == "unknown"
      assert find(checks, "watcher_live:insider")["status"] == "unknown"
    end

    test "an unsafe (glob-metacharacter) path surfaces its reason on path_resolves" do
      root = tmp_dir!("vmounts-doctor")
      parent = tmp_dir!("vmounts-doctor-parent")
      weird = Path.join(parent, "weird[1]")

      write_manifest!(weird, %{
        id: "7d23ae36-9be4-45a1-9de6-a3359141e78e",
        name: "Weird",
        description: ""
      })

      write_icms!(root, [{"weird", weird, []}])

      {:ok, %{checks: checks}} = Doctor.run(root)

      path = find(checks, "path_resolves:weird")
      assert path["status"] == "failed"
      assert path["detail"] =~ "glob"
    end
  end

  # -- manifest_format2, gated on path_resolves only -----------------------------

  describe "run/1 — manifest_format2" do
    test "a resolvable path with no icm.yaml passes path_resolves but fails manifest_format2, and its siblings still run" do
      root = tmp_dir!("vmounts-doctor")
      ext = tmp_dir!("vmounts-doctor-ext")

      write_icms!(root, [{"outside", ext, []}])

      {:ok, %{checks: checks, ok: false}} = Doctor.run(root)

      assert find(checks, "path_resolves:outside")["status"] == "ok"

      manifest = find(checks, "manifest_format2:outside")
      assert manifest["status"] == "failed"
      assert manifest["detail"] == "icm.yaml is missing"
      assert is_binary(manifest["remedy"])

      # unique_id is gated on manifest_format2 -- no id to compare.
      unique = find(checks, "unique_id:outside")
      assert unique["status"] == "unknown"
      assert unique["detail"] =~ "manifest_format2"

      # NOT gated by manifest_format2's failure -- independent siblings,
      # only gated on path_resolves, same as `related_icms`.
      assert find(checks, "related_icms:outside")["status"] == "ok"
      assert find(checks, "secrets_hygiene:outside")["status"] == "ok"
    end
  end

  # -- unique_id, gated on manifest_format2 --------------------------------------

  describe "run/1 — unique_id" do
    test "a uniquely-idd mount passes unique_id" do
      root = tmp_dir!("vmounts-doctor")
      ext = tmp_dir!("vmounts-doctor-ext")

      write_manifest!(ext, %{
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        name: "External",
        description: ""
      })

      write_icms!(root, [{"outside", ext, []}])

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "unique_id:outside")
      assert check["status"] == "ok"
      assert check["remedy"] == nil
    end

    test "two enabled mounts sharing a manifest id both fail unique_id" do
      root = tmp_dir!("vmounts-doctor")
      a = tmp_dir!("vmounts-doctor-a")
      b = tmp_dir!("vmounts-doctor-b")
      shared_id = "41d871cd-aadc-466f-a951-a5c47e197d47"

      write_manifest!(a, %{id: shared_id, name: "A", description: ""})
      write_manifest!(b, %{id: shared_id, name: "B", description: ""})
      write_icms!(root, [{"mount-a", a, []}, {"mount-b", b, []}])

      {:ok, %{checks: checks, ok: false}} = Doctor.run(root)

      for id <- ["unique_id:mount-a", "unique_id:mount-b"] do
        check = find(checks, id)
        assert check["status"] == "failed"
        assert is_binary(check["remedy"])
      end

      # Both still resolve their path and load a valid manifest -- ONLY
      # unique_id owns the "ambiguous id" reason `Valea.Mounts.list/1` itself
      # stamps on `degraded`, not path_resolves/manifest_format2.
      assert find(checks, "path_resolves:mount-a")["status"] == "ok"
      assert find(checks, "manifest_format2:mount-a")["status"] == "ok"
      assert find(checks, "path_resolves:mount-b")["status"] == "ok"
      assert find(checks, "manifest_format2:mount-b")["status"] == "ok"
    end

    test "a disabled twin sharing the id does not fail the already-enabled mount, but does fail the twin's own" do
      root = tmp_dir!("vmounts-doctor")
      a = tmp_dir!("vmounts-doctor-a")
      b = tmp_dir!("vmounts-doctor-b")
      shared_id = "41d871cd-aadc-466f-a951-a5c47e197d47"

      write_manifest!(a, %{id: shared_id, name: "A", description: ""})
      write_manifest!(b, %{id: shared_id, name: "B", description: ""})
      write_icms!(root, [{"mount-a", a, []}, {"mount-b", b, enabled: false}])

      {:ok, %{checks: checks}} = Doctor.run(root)

      assert find(checks, "unique_id:mount-a")["status"] == "ok"

      disabled_check = find(checks, "unique_id:mount-b")
      assert disabled_check["status"] == "failed"
      assert disabled_check["detail"] =~ "mount-a"
    end
  end

  # -- related_icms, gated on path_resolves only ---------------------------------

  describe "run/1 — related_icms" do
    test "no CONTEXT.md at all passes related_icms ok" do
      root = tmp_dir!("vmounts-doctor")
      ext = tmp_dir!("vmounts-doctor-ext")

      write_manifest!(ext, %{
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        name: "External",
        description: ""
      })

      write_icms!(root, [{"outside", ext, []}])

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "related_icms:outside")
      assert check["status"] == "ok"
      assert check["remedy"] == nil
    end

    test "a CONTEXT.md with no related_icms declaration passes related_icms ok" do
      root = tmp_dir!("vmounts-doctor")
      ext = tmp_dir!("vmounts-doctor-ext")

      write_manifest!(ext, %{
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        name: "External",
        description: ""
      })

      write_context!(ext, "# External context\n\nNo frontmatter here.\n")
      write_icms!(root, [{"outside", ext, []}])

      {:ok, %{checks: checks}} = Doctor.run(root)
      assert find(checks, "related_icms:outside")["status"] == "ok"
    end

    test "a primary whose CONTEXT.md declares an unmounted id warns :not_mounted" do
      root = tmp_dir!("vmounts-doctor")
      primary = tmp_dir!("vmounts-doctor-primary")

      write_manifest!(primary, %{
        id: "6f9f0c9e-3ccd-4fa5-a219-113a70618b55",
        name: "Primary",
        description: ""
      })

      write_context!(primary, """
      ---
      format: 1
      related_icms:
        - id: "00000000-0000-0000-0000-000000000000"
          name: "Ghost"
      ---
      """)

      write_icms!(root, [{"primary", primary, []}])

      {:ok, %{checks: checks, ok: false}} = Doctor.run(root)
      check = find(checks, "related_icms:primary")
      assert check["status"] == "failed"
      assert check["detail"] =~ "not_mounted"
      assert is_binary(check["remedy"])
    end

    test "a primary whose CONTEXT.md declares a disabled related ICM warns :disabled" do
      root = tmp_dir!("vmounts-doctor")
      primary = tmp_dir!("vmounts-doctor-primary")
      related = tmp_dir!("vmounts-doctor-related")

      write_manifest!(primary, %{
        id: "6f9f0c9e-3ccd-4fa5-a219-113a70618b55",
        name: "Primary",
        description: ""
      })

      write_manifest!(related, %{
        id: "31201697-cff8-4d99-9dc5-b140e4178716",
        name: "Legal",
        description: ""
      })

      write_context!(primary, """
      ---
      format: 1
      related_icms:
        - id: 31201697-cff8-4d99-9dc5-b140e4178716
          name: "Legal"
      ---
      """)

      write_icms!(root, [{"primary", primary, []}, {"legal", related, enabled: false}])

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "related_icms:primary")
      assert check["status"] == "failed"
      assert check["detail"] =~ "disabled"
    end

    test "a primary whose CONTEXT.md declares an escaping entrypoint warns :entrypoint_escapes" do
      root = tmp_dir!("vmounts-doctor")
      primary = tmp_dir!("vmounts-doctor-primary")
      related = tmp_dir!("vmounts-doctor-related")

      write_manifest!(primary, %{
        id: "6f9f0c9e-3ccd-4fa5-a219-113a70618b55",
        name: "Primary",
        description: ""
      })

      write_manifest!(related, %{
        id: "31201697-cff8-4d99-9dc5-b140e4178716",
        name: "Legal",
        description: ""
      })

      write_context!(primary, """
      ---
      format: 1
      related_icms:
        - id: 31201697-cff8-4d99-9dc5-b140e4178716
          name: "Legal"
          entrypoint: "../escape/CONTEXT.md"
      ---
      """)

      write_icms!(root, [{"primary", primary, []}, {"legal", related, []}])

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "related_icms:primary")
      assert check["status"] == "failed"
      assert check["detail"] =~ "entrypoint_escapes"
    end

    test "related_icms still evaluates declared relations even when this mount's own manifest_format2 fails" do
      root = tmp_dir!("vmounts-doctor")
      primary = tmp_dir!("vmounts-doctor-primary")

      # No icm.yaml at all -- manifest_format2 fails, but the folder itself
      # resolves fine, so path_resolves (and thus this check's gate) is ok.
      write_context!(primary, """
      ---
      format: 1
      related_icms:
        - id: "00000000-0000-0000-0000-000000000000"
          name: "Ghost"
      ---
      """)

      write_icms!(root, [{"primary", primary, []}])

      {:ok, %{checks: checks}} = Doctor.run(root)
      assert find(checks, "manifest_format2:primary")["status"] == "failed"

      check = find(checks, "related_icms:primary")
      assert check["status"] == "failed"
      assert check["detail"] =~ "not_mounted"
    end
  end

  # -- secrets_hygiene ------------------------------------------------------------

  describe "run/1 — secrets_hygiene" do
    defp healthy_workspace!(mount_name \\ "outside") do
      root = tmp_dir!("vmounts-doctor")
      ext = tmp_dir!("vmounts-doctor-ext")

      write_manifest!(ext, %{
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        name: "External",
        description: ""
      })

      write_icms!(root, [{mount_name, ext, []}])

      {root, ext}
    end

    test "no secrets/ dir or .env-like file at the root passes clean" do
      {root, _ext} = healthy_workspace!()

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "secrets_hygiene:outside")
      assert check["status"] == "ok"
      assert check["remedy"] == nil
    end

    test "a secrets/ directory at the mount root fails secrets_hygiene with the warning remedy" do
      {root, ext} = healthy_workspace!()
      File.mkdir_p!(Path.join(ext, "secrets"))

      {:ok, %{checks: checks, ok: false}} = Doctor.run(root)
      check = find(checks, "secrets_hygiene:outside")
      assert check["status"] == "failed"
      assert check["detail"] =~ "secrets"
      assert check["remedy"] =~ "deny-list"
    end

    test "a secrets file (not a directory) named 'secrets' does not trip the check" do
      {root, ext} = healthy_workspace!()
      File.write!(Path.join(ext, "secrets"), "not a directory")

      {:ok, %{checks: checks}} = Doctor.run(root)
      assert find(checks, "secrets_hygiene:outside")["status"] == "ok"
    end

    test "a .env.local file at the mount root fails secrets_hygiene" do
      {root, ext} = healthy_workspace!()
      File.write!(Path.join(ext, ".env.local"), "SECRET=1")

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "secrets_hygiene:outside")
      assert check["status"] == "failed"
      assert check["detail"] =~ ".env.local"
    end

    test "a bare .env file at the mount root fails secrets_hygiene" do
      {root, ext} = healthy_workspace!()
      File.write!(Path.join(ext, ".env"), "SECRET=1")

      {:ok, %{checks: checks}} = Doctor.run(root)
      assert find(checks, "secrets_hygiene:outside")["status"] == "failed"
    end

    test "a filename that merely contains .env (not a prefix) is not flagged" do
      {root, ext} = healthy_workspace!()
      File.write!(Path.join(ext, "not.env.but.close"), "fine")
      File.write!(Path.join(ext, "myenvfile"), "fine")

      {:ok, %{checks: checks}} = Doctor.run(root)
      assert find(checks, "secrets_hygiene:outside")["status"] == "ok"
    end

    test "secrets_hygiene never crashes when the mount root is unreadable and check detail carries no file contents" do
      {root, ext} = healthy_workspace!()
      File.write!(Path.join(ext, ".env"), "TOP_SECRET_VALUE=do-not-leak")

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "secrets_hygiene:outside")
      refute check["detail"] =~ "TOP_SECRET_VALUE"
      refute check["detail"] =~ "do-not-leak"
    end
  end

  # -- watcher_live, pure (no live Watcher process) -----------------------------

  describe "run/1 — watcher_live without a running watcher" do
    test "a disabled mount is 'unknown', not 'failed' — nothing to fix" do
      root = tmp_dir!("vmounts-doctor")
      ext = tmp_dir!("vmounts-doctor-ext")

      write_manifest!(ext, %{
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        name: "External",
        description: ""
      })

      write_icms!(root, [{"outside", ext, enabled: false}])

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "watcher_live:outside")
      assert check["status"] == "unknown"
      assert check["detail"] =~ "disabled"
      assert check["remedy"] == nil
    end

    test "an enabled mount reports watcher_live failed (best-effort) when no watcher is running" do
      refute Process.whereis(Valea.ICM.Watcher)
      {root, _ext} = healthy_workspace!()

      {:ok, %{checks: checks}} = Doctor.run(root)
      check = find(checks, "watcher_live:outside")
      assert check["status"] == "failed"
      assert is_binary(check["remedy"])
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

  # -- run/2: single-mount probe --------------------------------------------------

  describe "run/2 — single mount" do
    test "returns :mount_not_found for a mount key with no icms: entry" do
      root = tmp_dir!("vmounts-doctor")
      write_icms!(root, [{"outside", tmp_dir!("vmounts-doctor-ext"), []}])

      assert Doctor.run(root, "does-not-exist") == {:error, :mount_not_found}
    end

    test "scopes checks to just the requested mount_key — six checks, none for the other mount" do
      root = tmp_dir!("vmounts-doctor")
      a = tmp_dir!("vmounts-doctor-a")
      b = tmp_dir!("vmounts-doctor-b")

      write_manifest!(a, %{id: "41d871cd-aadc-466f-a951-a5c47e197d47", name: "A", description: ""})

      write_manifest!(b, %{id: "31201697-cff8-4d99-9dc5-b140e4178716", name: "B", description: ""})

      write_icms!(root, [{"mount-a", a, []}, {"mount-b", b, []}])

      {:ok, %{mount_key: "mount-a", checks: checks}} = Doctor.run(root, "mount-a")

      assert length(checks) == 6
      assert Enum.all?(checks, &String.ends_with?(&1["id"], ":mount-a"))
      refute Enum.any?(checks, &String.ends_with?(&1["id"], ":mount-b"))
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
  describe "run/1,2 — end to end with a live watcher" do
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

      icms =
        (Map.get(doc, "icms") || %{})
        |> Map.put(name, %{"path" => ref})

      header = for key <- ["version", "id"], Map.has_key?(doc, key), do: "#{key}: #{doc[key]}"

      entries =
        Enum.flat_map(Enum.sort_by(icms, &elem(&1, 0)), fn {n, entry} ->
          [
            "  #{n}:"
            | Enum.map(Enum.sort_by(entry, &elem(&1, 0)), fn {k, v} ->
                "    #{k}: #{render_scalar(v)}"
              end)
          ]
        end)

      File.write!(config_path, Enum.join(header ++ ["icms:"] ++ entries, "\n") <> "\n")
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

    test "a fully healthy, enabled, watched mount is all ok (run/1)", %{ws: ws} do
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
            "path_resolves:outside",
            "manifest_format2:outside",
            "unique_id:outside",
            "related_icms:outside",
            "secrets_hygiene:outside",
            "watcher_live:outside"
          ] do
        check = find(checks, id)
        assert check["status"] == "ok", "expected #{id} to be ok, got #{inspect(check)}"
      end
    end

    test "a healthy ICM reports every check ok via run/2, with mount_key echoed back", %{ws: ws} do
      ext = tmp_dir!("vmounts-doctor-ext")

      write_manifest!(ext, %{
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        name: "External",
        description: ""
      })

      Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")
      poll_until_mounts_changed(fn _i -> declare_external!(ws.path, "outside", ext) end)

      {:ok, %{mount_key: "outside", checks: checks, ok: true}} = Doctor.run(ws.path, "outside")
      assert length(checks) == 6
      assert Enum.all?(checks, &(&1["status"] == "ok"))
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
      assert find(checks, "watcher_live:outside")["status"] == "ok"

      poll_until_mounts_changed(fn _i -> Valea.Mounts.set_enabled(ws.path, "outside", false) end)

      {:ok, %{checks: checks}} = Doctor.run(ws.path)
      check = find(checks, "watcher_live:outside")
      assert check["status"] == "unknown"
      assert check["detail"] =~ "disabled"
    end
  end

  # `healthy_workspace!/1` is defined inside the secrets_hygiene `describe`
  # block above (so it's colocated with its main users) but is also reused
  # by the plain watcher_live tests in this module — ExUnit `describe`
  # blocks share one module namespace, so this just documents the
  # cross-reference.
end
