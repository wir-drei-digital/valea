defmodule ValeaWeb.MountsRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.Workspace.Manager

  # A fresh scaffold (T8) names its one seeded starter mount after the
  # workspace itself — naming the workspace "W" lands it at exactly
  # `mounts/w` (title "W"), the mount every `list_mounts`/`set_mount_enabled`
  # happy-path assertion below addresses (mirrors `IcmRpcTest`'s "Primary"
  # convention).
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

    # Legacy path-based `Manager.create/2` (v4, starter mount) — called
    # directly rather than through the `create_workspace` RPC, which is now
    # the C9 id-based surface (`Manager.create/1`, v5, no `mounts/`). This
    # suite exercises `mounts/w/...` starter-mount content the id-based
    # create can't provide yet (Phase 3 introduces the config-backed ICM
    # registry) — see `Valea.Api.Workspace`'s moduledoc.
    parent = Path.join(dir, "workspaces")
    {:ok, _} = Manager.create(parent, "W")
    %{"data" => %{"generation" => generation}} = rpc("get_workspace", %{})

    %{workspace: Path.join(parent, "W"), generation: generation}
  end

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  # Declares an external `icms:` entry directly in the workspace's existing
  # config/workspace.yaml, preserving version/id and every existing entry —
  # mirrors `Valea.Agents.SessionReadRootsTest`'s helper of the same
  # name/shape, retargeted from the retired `mounts:`/`kind: path`/`ref:`
  # shape (task 3.2) to `icms:`/`path:` (task 3.3).
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

  defp external_icm!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-mounts-rpc-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # A fresh id per call — post-task-3.2, `Mounts.list/1`/`mount/2` degrade
    # or reject TWO entries sharing a manifest id (`degrade_duplicate_ids/1`
    # / `:duplicate_id`), so every test that mounts more than one
    # `external_icm!/1` fixture needs each to carry its OWN id.
    Valea.Mounts.Manifest.write!(dir, %{
      id: Ecto.UUID.generate(),
      name: name,
      description: ""
    })

    dir
  end

  defp settings_allow(workspace) do
    workspace
    |> Path.join(".claude/settings.json")
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["permissions", "allow"])
  end

  # A bare, empty tmp directory with no `icm.yaml` at all (`:no_manifest`).
  defp bare_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-mounts-rpc-bare-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A real directory whose `icm.yaml` fails to parse (`{:invalid_manifest, _}`).
  defp invalid_manifest_dir! do
    dir = bare_dir!()
    File.write!(Path.join(dir, "icm.yaml"), "name: [unterminated")
    dir
  end

  # A real directory whose path contains a Claude Code permission-glob
  # metacharacter (`:unsafe_path`) -- `check_glob_safety/1` runs BEFORE
  # `check_folder/1`, so this need not even exist to trigger the reason, but
  # a real directory keeps the fixture honest.
  defp unsafe_glob_dir! do
    base = bare_dir!()
    dir = Path.join(base, "weird*name")
    File.mkdir_p!(dir)
    dir
  end

  @mount_fields [
    %{"mounts" => ["name", "title", "description", "relRoot", "root", "enabled", "degraded"]}
  ]

  @create_fields ["mountKey", "id"]

  # -- list_mounts --------------------------------------------------------

  describe "list_mounts" do
    test "happy path lists a mounted external ICM", %{
      workspace: workspace,
      generation: generation
    } do
      ext = external_icm!("Primary")

      assert %{"success" => true} =
               rpc(
                 "declare_mount",
                 %{"name" => "ignored", "ref" => ext, "generation" => generation},
                 ["declared"]
               )

      %{root: ext_root} =
        workspace |> Valea.Mounts.enabled() |> Enum.find(&(&1.name == "primary"))

      assert %{"success" => true, "data" => %{"mounts" => mounts}} =
               rpc("list_mounts", %{}, @mount_fields)

      assert [mount] = mounts
      assert mount["name"] == "primary"
      assert mount["title"] == "Primary"
      assert mount["relRoot"] == nil
      assert mount["root"] == ext_root
      assert mount["enabled"] == true
      assert mount["degraded"] == nil
    end

    test "includes a degraded mount (missing icm.yaml) alongside the healthy one", %{
      workspace: workspace,
      generation: generation
    } do
      ext = external_icm!("Primary")

      assert %{"success" => true} =
               rpc(
                 "declare_mount",
                 %{"name" => "ignored", "ref" => ext, "generation" => generation},
                 ["declared"]
               )

      broken = bare_dir!()
      declare_external!(workspace, "broken", broken)

      assert %{"success" => true, "data" => %{"mounts" => mounts}} =
               rpc("list_mounts", %{}, @mount_fields)

      assert mounts |> Enum.map(& &1["name"]) |> Enum.sort() == ["broken", "primary"]

      broken_mount = Enum.find(mounts, &(&1["name"] == "broken"))
      assert is_binary(broken_mount["degraded"])
      assert broken_mount["title"] == "broken"
      assert broken_mount["description"] == ""
      assert broken_mount["relRoot"] == nil
    end

    test "surfaces workspace_not_open when no workspace is open" do
      Manager.close()

      assert %{"success" => false, "errors" => errors} = rpc("list_mounts", %{}, @mount_fields)
      assert inspect(errors) =~ "workspace_not_open"
    end
  end

  # -- set_mount_enabled ----------------------------------------------------

  describe "set_mount_enabled" do
    test "happy path disables the mount, regenerates MOUNTS.md, and broadcasts on \"mounts\"", %{
      workspace: workspace,
      generation: generation
    } do
      ext = external_icm!("Primary")
      declare_external!(workspace, "primary", ext)

      Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

      assert %{"success" => true, "data" => %{"saved" => true}} =
               rpc(
                 "set_mount_enabled",
                 %{"name" => "primary", "enabled" => false, "generation" => generation},
                 ["saved"]
               )

      assert_receive {:mounts_changed}, 2000

      {:ok, doc} = YamlElixir.read_from_file(Path.join(workspace, "config/workspace.yaml"))
      assert doc["icms"]["primary"]["enabled"] == false

      mounts_md = File.read!(Path.join(workspace, "MOUNTS.md"))
      assert mounts_md =~ "## Deactivated"
      refute mounts_md =~ "@#{ext}/AGENTS.md"
    end

    test "a stale generation surfaces workspace_changed and does not write", %{
      workspace: workspace,
      generation: generation
    } do
      before = File.read!(Path.join(workspace, "config/workspace.yaml"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_mount_enabled",
                 %{"name" => "primary", "enabled" => false, "generation" => generation - 1},
                 ["saved"]
               )

      assert inspect(errors) =~ "workspace_changed"
      assert File.read!(Path.join(workspace, "config/workspace.yaml")) == before
    end

    test "an invalid mount name surfaces invalid_mount_name", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_mount_enabled",
                 %{"name" => "evil\nname", "enabled" => false, "generation" => generation},
                 ["saved"]
               )

      assert inspect(errors) =~ "invalid_mount_name"
    end

    test "a name with no icms: entry surfaces mount_not_found and audits nothing", %{
      generation: generation
    } do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_mount_enabled",
                 %{"name" => "nope", "enabled" => false, "generation" => generation},
                 ["saved"]
               )

      assert inspect(errors) =~ "mount_not_found"

      {:ok, entries} = Valea.Audit.entries(50)
      refute Enum.any?(entries, &(&1["type"] in ["icm_enabled", "icm_disabled"]))
    end

    # A2-T4: the managed `.claude/settings.json` regenerates on this
    # mutation too (not just at session start), so an external mount's
    # `Read(<abs>/**)` allow tracks `enabled` state without a workspace
    # reopen. The external mount here is declared directly on disk (a
    # hand-edited config, not through this RPC), so the settings file
    # written at workspace-scaffold time predates it and starts stale; ANY
    # subsequent mutation — even one unrelated to "ext" itself — must pick
    # it up because `write!/1` reads `Mounts.enabled/1` fresh every time.
    test "a hand-declared external mount's Read allow appears after the next mutation and disappears when disabled",
         %{workspace: workspace, generation: generation} do
      ext = external_icm!("Ext")
      declare_external!(workspace, "ext", ext)

      stale_allow = settings_allow(workspace)
      assert stale_allow == ["Read(./**)"]

      # An unrelated mutation (mounting a second, harmless ICM via the RPC)
      # still refreshes settings.json's allow list.
      other = external_icm!("Other")

      assert %{"success" => true} =
               rpc(
                 "declare_mount",
                 %{"name" => "ignored", "ref" => other, "generation" => generation},
                 ["declared"]
               )

      %{root: ext_root} =
        workspace |> Valea.Mounts.enabled() |> Enum.find(&(&1.name == "ext"))

      %{root: other_root} =
        workspace |> Valea.Mounts.enabled() |> Enum.find(&(&1.name == "other"))

      allow_after_unrelated_mutation = settings_allow(workspace)
      assert "Read(#{ext_root}/**)" in allow_after_unrelated_mutation

      assert %{"success" => true} =
               rpc(
                 "set_mount_enabled",
                 %{"name" => "ext", "enabled" => false, "generation" => generation},
                 ["saved"]
               )

      allow_after_disable = settings_allow(workspace)
      refute "Read(#{ext_root}/**)" in allow_after_disable
      assert "Read(#{other_root}/**)" in allow_after_disable
    end
  end

  # -- create_mount ---------------------------------------------------------

  # Target folder for `create_mount`'s new path-based signature (task
  # 3.3+3.5: `Mounts.create/3` seeds the portable `priv/icm_template/`
  # tree into an EXTERNAL folder at the given `path`, replacing the old
  # `name`+`description` embedded-scaffold signature).
  defp create_target! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-mounts-rpc-create-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "create_mount" do
    test "happy path scaffolds a new mount visible in list_mounts and MOUNTS.md, and broadcasts",
         %{workspace: workspace, generation: generation} do
      Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")
      target = create_target!()

      assert %{"success" => true, "data" => %{"mountKey" => mount_key, "id" => id}} =
               rpc(
                 "create_mount",
                 %{"name" => "New Clients", "path" => target, "generation" => generation},
                 @create_fields
               )

      assert mount_key == "new-clients"
      assert {:ok, _} = Ecto.UUID.cast(id)
      assert_receive {:mounts_changed}, 2000

      assert File.exists?(Path.join(target, "icm.yaml"))
      assert File.exists?(Path.join(target, "AGENTS.md"))
      assert File.exists?(Path.join(target, "CLAUDE.md"))

      assert %{"success" => true, "data" => %{"mounts" => mounts}} =
               rpc("list_mounts", %{}, @mount_fields)

      assert created = Enum.find(mounts, &(&1["name"] == mount_key))
      assert created["title"] == "New Clients"
      assert created["enabled"] == true
      assert created["degraded"] == nil

      mounts_md = File.read!(Path.join(workspace, "MOUNTS.md"))
      assert mounts_md =~ "@#{created["root"]}/AGENTS.md"
    end

    test "a stale generation surfaces workspace_changed and does not create the directory", %{
      generation: generation
    } do
      target = create_target!()

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_mount",
                 %{"name" => "Nope", "path" => target, "generation" => generation - 1},
                 @create_fields
               )

      assert inspect(errors) =~ "workspace_changed"
      refute File.exists?(Path.join(target, "icm.yaml"))
    end

    test "creating twice at the same path surfaces already_exists", %{generation: generation} do
      target = create_target!()

      assert %{"success" => true} =
               rpc(
                 "create_mount",
                 %{"name" => "Dup", "path" => target, "generation" => generation},
                 @create_fields
               )

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_mount",
                 %{"name" => "Dup", "path" => target, "generation" => generation},
                 @create_fields
               )

      assert inspect(errors) =~ "already_exists"
    end
  end

  # -- declare_mount --------------------------------------------------------

  describe "declare_mount" do
    test "happy path: writes config (icms:/path:/enabled), regenerates MOUNTS.md + settings, audits, and broadcasts",
         %{workspace: workspace, generation: generation} do
      Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")
      ext = external_icm!("Outside")

      assert %{"success" => true, "data" => %{"declared" => true}} =
               rpc(
                 "declare_mount",
                 %{"name" => "ignored", "ref" => ext, "generation" => generation},
                 ["declared"]
               )

      assert_receive {:mounts_changed}, 2000

      {:ok, doc} = YamlElixir.read_from_file(Path.join(workspace, "config/workspace.yaml"))
      assert doc["icms"]["outside"]["path"] == ext
      assert doc["icms"]["outside"]["enabled"] == true

      %{root: ext_root} =
        workspace |> Valea.Mounts.enabled() |> Enum.find(&(&1.name == "outside"))

      mounts_md = File.read!(Path.join(workspace, "MOUNTS.md"))
      assert mounts_md =~ "mounted from: #{ext_root}"
      assert mounts_md =~ "@#{ext_root}/AGENTS.md"

      assert "Read(#{ext_root}/**)" in settings_allow(workspace)

      assert %{"success" => true, "data" => %{"mounts" => mounts}} =
               rpc("list_mounts", %{}, @mount_fields)

      outside = Enum.find(mounts, &(&1["name"] == "outside"))
      assert outside["relRoot"] == nil
      assert outside["root"] == ext_root
      assert outside["enabled"] == true
      assert outside["degraded"] == nil

      {:ok, entries} = Valea.Audit.entries(10)
      entry = Enum.find(entries, &(&1["type"] == "icm_mounted"))
      assert entry["mount_key"] == "outside"
      assert entry["path"] == ext_root
    end

    # Mirrors `Valea.MountsTest`'s own "~ expansion" fixture — a real,
    # uniquely-named, self-cleaning directory planted directly under the
    # ACTUAL $HOME (there is no sandboxable stand-in for `~`).
    test "preserves a ~-form ref exactly, not its resolved absolute path", %{
      workspace: workspace,
      generation: generation
    } do
      unique =
        "valea-mounts-rpc-tilde-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"

      home_child = Path.join(System.user_home!(), unique)
      on_exit(fn -> File.rm_rf!(home_child) end)
      File.mkdir_p!(home_child)

      Valea.Mounts.Manifest.write!(home_child, %{
        id: "32e69771-c3d2-4c3c-83fa-aa47d023fadc",
        name: "Tilde",
        description: ""
      })

      ref = "~/#{unique}"

      assert %{"success" => true, "data" => %{"declared" => true}} =
               rpc(
                 "declare_mount",
                 %{"name" => "ignored", "ref" => ref, "generation" => generation},
                 ["declared"]
               )

      {:ok, doc} = YamlElixir.read_from_file(Path.join(workspace, "config/workspace.yaml"))
      assert doc["icms"]["tilde"]["path"] == ref
    end

    test "preserves an already-declared entry's path when declaring a second one", %{
      workspace: workspace,
      generation: generation
    } do
      other_ext = external_icm!("Other")
      declare_external!(workspace, "other", other_ext)

      ext = external_icm!("Outside")

      assert %{"success" => true} =
               rpc(
                 "declare_mount",
                 %{"name" => "ignored", "ref" => ext, "generation" => generation},
                 ["declared"]
               )

      {:ok, doc} = YamlElixir.read_from_file(Path.join(workspace, "config/workspace.yaml"))
      assert doc["icms"]["other"]["path"] == other_ext
      assert doc["icms"]["outside"]["path"] == ext
    end

    test "a stale generation surfaces workspace_changed and does not write", %{
      workspace: workspace,
      generation: generation
    } do
      before = File.read!(Path.join(workspace, "config/workspace.yaml"))
      ext = external_icm!("Ext")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "declare_mount",
                 %{"name" => "outside", "ref" => ext, "generation" => generation - 1},
                 ["declared"]
               )

      assert inspect(errors) =~ "workspace_changed"
      assert File.read!(Path.join(workspace, "config/workspace.yaml")) == before
    end

    # `declare_mount`'s `name` argument is a stopgap-era leftover: the
    # actual mount key is now SERVER-DERIVED from the target ICM's own
    # manifest name (`Mounts.unique_mount_key/2`, always a safe
    # `Scaffold.slugify/1` output), so there is no caller-supplied "mount
    # name" left to validate here any more — unlike `set_mount_enabled`
    # (see its own "an invalid mount name" test above), whose `name`
    # argument IS still the config key being looked up.
    test "the name argument is accepted but unused — even a control-char string doesn't block the declare",
         %{generation: generation} do
      ext = external_icm!("Ext")

      assert %{"success" => true, "data" => %{"declared" => true}} =
               rpc(
                 "declare_mount",
                 %{"name" => "evil\nname", "ref" => ext, "generation" => generation},
                 ["declared"]
               )
    end

    # All EIGHT `Valea.Mounts.External.validate_ref/2` reasons, each mapped
    # to its own RPC error code (`Valea.Api.Mounts.error_for/1`) -- three
    # here, the remaining five in the next test.
    test "maps :home_or_root, :not_found, and :not_absolute to distinct RPC error codes", %{
      generation: generation
    } do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "declare_mount",
                 %{"name" => "a", "ref" => "/", "generation" => generation},
                 ["declared"]
               )

      assert inspect(errors) =~ "home_or_root"

      missing =
        Path.join(
          System.tmp_dir!(),
          "valea-mounts-rpc-missing-#{System.unique_integer([:positive])}"
        )

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "declare_mount",
                 %{"name" => "b", "ref" => missing, "generation" => generation},
                 ["declared"]
               )

      assert inspect(errors) =~ "not_found"

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "declare_mount",
                 %{"name" => "c", "ref" => "relative/path", "generation" => generation},
                 ["declared"]
               )

      assert inspect(errors) =~ "not_absolute"
    end

    test "maps :inside_workspace, :ancestor_of_workspace, :no_manifest, invalid_manifest, and :unsafe_path to distinct RPC error codes",
         %{workspace: workspace, generation: generation} do
      cases = [
        {workspace, "inside_workspace"},
        {Path.dirname(workspace), "ancestor_of_workspace"},
        {bare_dir!(), "no_manifest"},
        {invalid_manifest_dir!(), "invalid_manifest"},
        {unsafe_glob_dir!(), "unsafe_path"}
      ]

      for {{ref, code}, idx} <- Enum.with_index(cases) do
        assert %{"success" => false, "errors" => errors} =
                 rpc(
                   "declare_mount",
                   %{"name" => "n#{idx}", "ref" => ref, "generation" => generation},
                   ["declared"]
                 )

        assert inspect(errors) =~ code
      end
    end
  end

  # -- undeclare_mount ------------------------------------------------------

  describe "undeclare_mount" do
    test "happy path: removes the config entry, leaves the folder, regenerates, audits, and broadcasts",
         %{workspace: workspace, generation: generation} do
      ext = external_icm!("Ext")
      declare_external!(workspace, "outside", ext)

      %{root: ext_root} =
        workspace |> Valea.Mounts.enabled() |> Enum.find(&(&1.name == "outside"))

      Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

      assert %{"success" => true, "data" => %{"undeclared" => true}} =
               rpc(
                 "undeclare_mount",
                 %{"name" => "outside", "generation" => generation},
                 ["undeclared"]
               )

      assert_receive {:mounts_changed}, 2000

      {:ok, doc} = YamlElixir.read_from_file(Path.join(workspace, "config/workspace.yaml"))
      refute Map.has_key?(doc["icms"] || %{}, "outside")

      assert File.dir?(ext_root)
      assert File.exists?(Path.join(ext_root, "icm.yaml"))

      assert %{"success" => true, "data" => %{"mounts" => mounts}} =
               rpc("list_mounts", %{}, @mount_fields)

      refute Enum.any?(mounts, &(&1["name"] == "outside"))

      mounts_md = File.read!(Path.join(workspace, "MOUNTS.md"))
      refute mounts_md =~ ext_root

      {:ok, entries} = Valea.Audit.entries(10)
      entry = Enum.find(entries, &(&1["type"] == "icm_unmounted"))
      assert entry["mount_key"] == "outside"
      assert entry["path"] == ext_root
    end

    test "a stale generation surfaces workspace_changed and does not write", %{
      workspace: workspace,
      generation: generation
    } do
      ext = external_icm!("Ext")
      declare_external!(workspace, "outside", ext)
      before = File.read!(Path.join(workspace, "config/workspace.yaml"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "undeclare_mount",
                 %{"name" => "outside", "generation" => generation - 1},
                 ["undeclared"]
               )

      assert inspect(errors) =~ "workspace_changed"
      assert File.read!(Path.join(workspace, "config/workspace.yaml")) == before
    end

    test "errors mount_not_found for a name with no config entry at all", %{
      generation: generation
    } do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "undeclare_mount",
                 %{"name" => "ghost", "generation" => generation},
                 ["undeclared"]
               )

      assert inspect(errors) =~ "mount_not_found"
    end

    # "w" is the legacy v4 scaffold's PHYSICAL mounts/w folder — it exists
    # on disk but, post-task-3.2, was never registered as an `icms:` entry
    # (config truth), so it's exactly as unmounted as "ghost" above. This
    # confirms undeclare_mount never touches a stray physical folder that
    # merely shares a config-key-shaped name.
    test "errors mount_not_found for a name that is a physical (but unregistered) legacy folder, and never touches it",
         %{workspace: workspace, generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "undeclare_mount",
                 %{"name" => "w", "generation" => generation},
                 ["undeclared"]
               )

      assert inspect(errors) =~ "mount_not_found"
      assert File.dir?(Path.join(workspace, "mounts/w"))
    end
  end

  # -- mounts_doctor ----------------------------------------------------------

  describe "mounts_doctor" do
    test "returns the mounts doctor section, ok for a healthy mounted ICM", %{
      workspace: workspace,
      generation: generation
    } do
      ext = external_icm!("Primary")
      Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")
      declare_external!(workspace, "primary", ext)
      # `declare_external!/3` writes config/workspace.yaml directly (not via
      # the RPC), so the live ICM Watcher only picks it up on its own
      # debounced filesystem poll — wait for that before asking the doctor,
      # so `watcher_live` isn't checked against a stale watched-root set.
      assert_receive {:mounts_changed}, 2000

      assert %{"success" => true, "data" => %{"ok" => ok, "checks" => checks}} =
               rpc("mounts_doctor", %{"generation" => generation}, ["ok", "checks"])

      assert ok == true

      assert Enum.any?(
               checks,
               &(&1["id"] == "manifest_ok:external:primary" and &1["status"] == "ok")
             )
    end

    test "surfaces a failing external mount's checks and flips ok to false", %{
      workspace: workspace,
      generation: generation
    } do
      declare_external!(workspace, "outside", "/does/not/exist")

      assert %{"success" => true, "data" => %{"ok" => ok, "checks" => checks}} =
               rpc("mounts_doctor", %{"generation" => generation}, ["ok", "checks"])

      assert ok == false

      assert Enum.any?(
               checks,
               &(&1["id"] == "ref_resolves:external:outside" and &1["status"] == "failed")
             )
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc("mounts_doctor", %{"generation" => generation - 1}, ["ok", "checks"])

      assert inspect(errors) =~ "workspace_changed"
    end

    # `check_generation/1` guards BEFORE `Doctor.run/0` ever runs, and it
    # answers `:workspace_changed` for ANY generation (matching or not) once
    # `Manager.close/0` has nilled the workspace out (see
    # `Valea.Workspace.Manager.handle_call({:check_generation, _}, _, %{workspace: nil})`)
    # -- so `Doctor.run/0`'s OWN `:no_workspace` branch is unreachable
    # through this generation-guarded action, same as `mail_doctor`
    # (`Valea.Api.Mail`'s doctor action has no analogous "workspace_not_open"
    # test either, for the identical reason).
    test "with no workspace open, the generation guard reports workspace_changed (not workspace_not_open)" do
      Manager.close()

      assert %{"success" => false, "errors" => errors} =
               rpc("mounts_doctor", %{"generation" => 1}, ["ok", "checks"])

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- set_mount_enabled: external-mount audit (A2-T8) -----------------------

  describe "set_mount_enabled — external-mount audit" do
    test "auditing an EXTERNAL mount's toggle carries name + resolved path", %{
      workspace: workspace,
      generation: generation
    } do
      ext = external_icm!("Ext")
      declare_external!(workspace, "outside", ext)

      %{root: ext_root} =
        workspace |> Valea.Mounts.enabled() |> Enum.find(&(&1.name == "outside"))

      assert %{"success" => true} =
               rpc(
                 "set_mount_enabled",
                 %{"name" => "outside", "enabled" => false, "generation" => generation},
                 ["saved"]
               )

      {:ok, entries} = Valea.Audit.entries(10)
      disabled = Enum.find(entries, &(&1["type"] == "icm_disabled"))
      assert disabled["mount_key"] == "outside"
      assert disabled["path"] == ext_root

      assert %{"success" => true} =
               rpc(
                 "set_mount_enabled",
                 %{"name" => "outside", "enabled" => true, "generation" => generation},
                 ["saved"]
               )

      {:ok, entries2} = Valea.Audit.entries(10)
      enabled = Enum.find(entries2, &(&1["type"] == "icm_enabled"))
      assert enabled["mount_key"] == "outside"
      assert enabled["path"] == ext_root
    end

    # Every mount is external now (task 3.2) — there is no more "embedded,
    # never audited" carve-out; `Valea.Mounts.set_enabled/3` audits every
    # successful toggle unconditionally. The only way a toggle audits
    # nothing is when it doesn't succeed at all (see the "name with no
    # icms: entry" test in the `set_mount_enabled` describe block above,
    # which covers that case for this same action).
    test "toggling an unmounted name is never audited (no embedded carve-out exists any more)", %{
      generation: generation
    } do
      assert %{"success" => false} =
               rpc(
                 "set_mount_enabled",
                 %{"name" => "w", "enabled" => false, "generation" => generation},
                 ["saved"]
               )

      {:ok, entries} = Valea.Audit.entries(50)
      refute Enum.any?(entries, &(&1["type"] in ["icm_enabled", "icm_disabled"]))
    end
  end
end
