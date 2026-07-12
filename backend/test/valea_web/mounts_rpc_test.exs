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

    parent = Path.join(dir, "workspaces")
    rpc("create_workspace", %{"parentDir" => parent, "name" => "W"})
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

  # Declares an external (kind: "path") mount in the workspace's existing
  # config/workspace.yaml, preserving version/id and every existing mount
  # entry — mirrors `Valea.Agents.SessionReadRootsTest`'s helper of the same
  # name/shape.
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
        "valea-mounts-rpc-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Valea.Mounts.Manifest.write!(dir, %{id: "ext-id", name: name, description: ""})
    dir
  end

  defp settings_allow(workspace) do
    workspace
    |> Path.join(".claude/settings.json")
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["permissions", "allow"])
  end

  @mount_fields [
    %{"mounts" => ["name", "title", "description", "relRoot", "enabled", "degraded"]}
  ]

  # -- list_mounts --------------------------------------------------------

  describe "list_mounts" do
    test "happy path lists the scaffolded starter mount" do
      assert %{"success" => true, "data" => %{"mounts" => mounts}} =
               rpc("list_mounts", %{}, @mount_fields)

      assert [mount] = mounts
      assert mount["name"] == "w"
      assert mount["title"] == "W"
      assert mount["relRoot"] == "mounts/w"
      assert mount["enabled"] == true
      assert mount["degraded"] == nil
    end

    test "includes a degraded mount (missing icm.yaml) alongside the healthy one", %{
      workspace: workspace
    } do
      File.mkdir_p!(Path.join(workspace, "mounts/broken"))

      assert %{"success" => true, "data" => %{"mounts" => mounts}} =
               rpc("list_mounts", %{}, @mount_fields)

      assert mounts |> Enum.map(& &1["name"]) |> Enum.sort() == ["broken", "w"]

      broken = Enum.find(mounts, &(&1["name"] == "broken"))
      assert is_binary(broken["degraded"])
      assert broken["title"] == "broken"
      assert broken["description"] == ""
      assert broken["relRoot"] == "mounts/broken"
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
      Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

      assert %{"success" => true, "data" => %{"saved" => true}} =
               rpc(
                 "set_mount_enabled",
                 %{"name" => "w", "enabled" => false, "generation" => generation},
                 ["saved"]
               )

      assert_receive {:mounts_changed}, 2000

      {:ok, doc} = YamlElixir.read_from_file(Path.join(workspace, "config/workspace.yaml"))
      assert doc["mounts"]["w"]["enabled"] == false

      mounts_md = File.read!(Path.join(workspace, "MOUNTS.md"))
      assert mounts_md =~ "## Deactivated"
      refute mounts_md =~ "@mounts/w/AGENTS.md"
    end

    test "a stale generation surfaces workspace_changed and does not write", %{
      workspace: workspace,
      generation: generation
    } do
      before = File.read!(Path.join(workspace, "config/workspace.yaml"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_mount_enabled",
                 %{"name" => "w", "enabled" => false, "generation" => generation - 1},
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

    # A2-T4: the managed `.claude/settings.json` regenerates on this
    # mutation too (not just at session start), so an external mount's
    # `Read(<abs>/**)` allow tracks `enabled` state without a workspace
    # reopen. The external mount here is declared directly on disk (a
    # hand-edited config, not through this RPC — Plan A2's declare RPC is a
    # later task), so the settings file written at workspace-scaffold time
    # predates it and starts stale; ANY subsequent mutation — even one
    # unrelated to "ext" itself — must pick it up because `write!/1` reads
    # `Mounts.enabled/1` fresh every time.
    test "a hand-declared external mount's Read allow appears after the next mutation and disappears when disabled",
         %{workspace: workspace, generation: generation} do
      ext = external_icm!("Ext")
      declare_external!(workspace, "ext", ext)

      stale_allow = settings_allow(workspace)
      assert stale_allow == ["Read(./**)"]

      assert %{"success" => true} =
               rpc(
                 "set_mount_enabled",
                 %{"name" => "w", "enabled" => true, "generation" => generation},
                 ["saved"]
               )

      %{root: ext_root} =
        workspace |> Valea.Mounts.enabled() |> Enum.find(&(&1.name == "ext"))

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
      assert allow_after_disable == ["Read(./**)"]
    end
  end

  # -- create_mount ---------------------------------------------------------

  describe "create_mount" do
    test "happy path scaffolds a new mount visible in list_mounts and MOUNTS.md, and broadcasts",
         %{workspace: workspace, generation: generation} do
      Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

      assert %{"success" => true, "data" => %{"relRoot" => rel_root}} =
               rpc(
                 "create_mount",
                 %{
                   "name" => "New Clients",
                   "description" => "New client intake",
                   "generation" => generation
                 },
                 ["relRoot"]
               )

      assert rel_root == "mounts/new-clients"
      assert_receive {:mounts_changed}, 2000

      assert File.exists?(Path.join([workspace, rel_root, "icm.yaml"]))
      assert File.exists?(Path.join([workspace, rel_root, "AGENTS.md"]))
      assert File.read!(Path.join([workspace, rel_root, "CLAUDE.md"])) == "@AGENTS.md\n"

      assert %{"success" => true, "data" => %{"mounts" => mounts}} =
               rpc("list_mounts", %{}, @mount_fields)

      assert created = Enum.find(mounts, &(&1["relRoot"] == rel_root))
      assert created["title"] == "New Clients"
      assert created["description"] == "New client intake"
      assert created["enabled"] == true
      assert created["degraded"] == nil

      mounts_md = File.read!(Path.join(workspace, "MOUNTS.md"))
      assert mounts_md =~ "@mounts/new-clients/AGENTS.md"
    end

    test "a stale generation surfaces workspace_changed and does not create the directory", %{
      workspace: workspace,
      generation: generation
    } do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_mount",
                 %{"name" => "Nope", "description" => "", "generation" => generation - 1},
                 ["relRoot"]
               )

      assert inspect(errors) =~ "workspace_changed"
      refute File.exists?(Path.join(workspace, "mounts/nope"))
    end

    test "a slug collision surfaces already_exists", %{generation: generation} do
      assert %{"success" => true} =
               rpc(
                 "create_mount",
                 %{"name" => "Dup", "description" => "", "generation" => generation},
                 ["relRoot"]
               )

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_mount",
                 %{"name" => "Dup", "description" => "", "generation" => generation},
                 ["relRoot"]
               )

      assert inspect(errors) =~ "already_exists"
    end
  end
end
