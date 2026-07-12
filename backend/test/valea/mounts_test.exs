defmodule Valea.MountsTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager

  defp write_manifest!(mount_dir, attrs) do
    File.mkdir_p!(mount_dir)
    File.write!(Path.join(mount_dir, "icm.yaml"), Manifest.render(attrs))
  end

  defp write_workspace_yaml!(root, contents) do
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/workspace.yaml"), contents)
  end

  defp mount_dir(root, name), do: Path.join([root, "mounts", name])

  describe "list/1 — discovery" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "valea-mounts-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "no mounts directory yields an empty list", %{root: root} do
      assert Mounts.list(root) == []
    end

    test "discovers two valid mounts + one manifest-less (degraded) dir, sorted by name", %{
      root: root
    } do
      write_manifest!(mount_dir(root, "a"), %{id: "id-a", name: "A", description: ""})
      write_manifest!(mount_dir(root, "b"), %{id: "id-b", name: "B", description: ""})
      # "c" exists on disk but has no icm.yaml at all -> degraded, still listed.
      File.mkdir_p!(mount_dir(root, "c"))

      mounts = Mounts.list(root)

      assert Enum.map(mounts, & &1.name) == ["a", "b", "c"]
      assert length(mounts) == 3
      assert root |> Mounts.enabled() |> Enum.map(& &1.name) == ["a", "b"]

      [a, b, c] = mounts

      assert a.rel_root == "mounts/a"
      assert a.root == Path.expand(mount_dir(root, "a"))
      assert a.degraded == nil
      assert a.enabled == true
      assert %Manifest{name: "A"} = a.manifest

      assert b.degraded == nil
      assert %Manifest{name: "B"} = b.manifest

      assert c.degraded != nil
      assert is_binary(c.degraded)
      assert c.manifest == nil
      # config has no mounts: section at all -> absent means enabled by default,
      # even for a degraded mount (degraded is what excludes it from enabled/1).
      assert c.enabled == true
    end

    test "a broken (invalid YAML) manifest is degraded, not a crash", %{root: root} do
      dir = mount_dir(root, "broken")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "icm.yaml"), "name: [unterminated")

      [m] = Mounts.list(root)
      assert m.degraded != nil
      assert m.manifest == nil
    end

    test "a hand-edited non-string manifest id does not crash discovery", %{root: root} do
      dir = mount_dir(root, "weird")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "icm.yaml"), "format: 1\nid: 12345\nname: \"Weird\"\n")

      [m] = Mounts.list(root)
      assert m.degraded == nil
      assert m.manifest.id == 12_345
    end

    test "config mounts:{b: {enabled: false}} disables b in enabled/1 but list/1 still shows it",
         %{root: root} do
      write_manifest!(mount_dir(root, "a"), %{id: "id-a", name: "A", description: ""})
      write_manifest!(mount_dir(root, "b"), %{id: "id-b", name: "B", description: ""})
      File.mkdir_p!(mount_dir(root, "c"))

      write_workspace_yaml!(root, """
      version: 3
      id: ws-id
      mounts:
        b:
          enabled: false
      """)

      enabled_names = root |> Mounts.enabled() |> Enum.map(& &1.name)
      assert enabled_names == ["a"]
      refute "b" in enabled_names
      # the degraded mount never appears in enabled/1 either, config or not.
      refute "c" in enabled_names

      list = Mounts.list(root)
      assert Enum.map(list, & &1.name) == ["a", "b", "c"]
      b = Enum.find(list, &(&1.name == "b"))
      assert b.enabled == false
      assert b.degraded == nil
    end
  end

  describe "mount_for/2" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "valea-mounts-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      write_manifest!(mount_dir(root, "a"), %{id: "id-a", name: "A", description: ""})
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "maps a path under mounts/<name> to that mount", %{root: root} do
      assert %{name: "a"} = Mounts.mount_for(root, "mounts/a/Offers/X.md")
    end

    test "returns nil for a path outside any mounts/ subtree", %{root: root} do
      assert Mounts.mount_for(root, "sources/x") == nil
    end

    test "returns nil for a mounts/<name> that isn't actually discovered", %{root: root} do
      assert Mounts.mount_for(root, "mounts/ghost/x.md") == nil
    end

    test "returns nil for a bare mounts path with no name segment", %{root: root} do
      assert Mounts.mount_for(root, "mounts") == nil
    end
  end

  describe "set_enabled/2 — current workspace" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        )

      System.put_env("VALEA_APP_DIR", dir)
      Manager.close()
      {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "W")
      # A fresh scaffold (T8) mints its own real mount from the template's
      # seed content — clear it so this suite's own hand-built mounts are
      # the only ones `Mounts.list/1` sees.
      ws.path |> Path.join("mounts/*") |> Path.wildcard() |> Enum.each(&File.rm_rf!/1)

      on_exit(fn ->
        Manager.close()
        File.rm_rf!(dir)
        System.delete_env("VALEA_APP_DIR")
      end)

      %{ws: ws}
    end

    test "creates the mounts section from scratch, preserving version/id", %{ws: ws} do
      config_path = Path.join(ws.path, "config/workspace.yaml")
      {:ok, before_doc} = YamlElixir.read_from_file(config_path)

      assert :ok = Mounts.set_enabled("a", false)

      {:ok, doc} = YamlElixir.read_from_file(config_path)
      assert doc["version"] == before_doc["version"]
      assert doc["id"] == before_doc["id"]
      assert doc["mounts"]["a"]["enabled"] == false
    end

    test "round-trips and preserves version/id + reserved kind/ref keys on another mount", %{
      ws: ws
    } do
      config_path = Path.join(ws.path, "config/workspace.yaml")
      {:ok, %{"id" => id}} = YamlElixir.read_from_file(config_path)

      File.write!(config_path, """
      version: 3
      id: #{id}
      mounts:
        a:
          enabled: true
        b:
          kind: git
          ref: "origin/main"
      """)

      assert :ok = Mounts.set_enabled("a", false)

      {:ok, doc} = YamlElixir.read_from_file(config_path)
      assert doc["version"] == 3
      assert doc["id"] == id
      assert doc["mounts"]["a"]["enabled"] == false
      assert doc["mounts"]["b"]["kind"] == "git"
      assert doc["mounts"]["b"]["ref"] == "origin/main"
    end

    test "is atomic: no stray .tmp file left behind", %{ws: ws} do
      assert :ok = Mounts.set_enabled("a", true)
      refute File.exists?(Path.join(ws.path, "config/workspace.yaml.tmp"))
    end

    test "list/1 reflects a disabled mount after set_enabled", %{ws: ws} do
      write_manifest!(Path.join([ws.path, "mounts", "a"]), %{
        id: "id-a",
        name: "A",
        description: ""
      })

      assert :ok = Mounts.set_enabled("a", false)

      [m] = Mounts.list(ws.path)
      assert m.enabled == false
    end

    test "rejects a name containing a path separator" do
      assert {:error, _} = Mounts.set_enabled("a/b", true)
    end

    test "rejects a name containing .." do
      assert {:error, _} = Mounts.set_enabled("..", true)
    end

    test "existing config with valid version/id but broken YAML: set_enabled errors and does not touch the file",
         %{ws: ws} do
      config_path = Path.join(ws.path, "config/workspace.yaml")

      File.write!(config_path, """
      version: 3
      id: some-real-workspace-id
      mounts:
        a:
          enabled: [unterminated
      """)

      before_bytes = File.read!(config_path)

      assert {:error, _reason} = Mounts.set_enabled("a", false)

      assert File.read!(config_path) == before_bytes
    end

    test "rejects an empty name" do
      assert {:error, _} = Mounts.set_enabled("", true)
    end
  end

  describe "zero-arity variants delegate to the current workspace" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        )

      System.put_env("VALEA_APP_DIR", dir)
      Manager.close()
      {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "W")
      # A fresh scaffold (T8) mints its own real mount from the template's
      # seed content — clear it so this suite's own hand-built mounts are
      # the only ones `Mounts.list/1` sees.
      ws.path |> Path.join("mounts/*") |> Path.wildcard() |> Enum.each(&File.rm_rf!/1)

      on_exit(fn ->
        Manager.close()
        File.rm_rf!(dir)
        System.delete_env("VALEA_APP_DIR")
      end)

      %{ws: ws}
    end

    test "list/0 and enabled/0 mirror the /1 forms", %{ws: ws} do
      write_manifest!(Path.join([ws.path, "mounts", "a"]), %{
        id: "id-a",
        name: "A",
        description: ""
      })

      assert {:ok, [%{name: "a"}]} = Mounts.list()
      assert {:ok, [%{name: "a"}]} = Mounts.enabled()
    end

    test "mount_for/1 resolves against the current workspace", %{ws: ws} do
      write_manifest!(Path.join([ws.path, "mounts", "a"]), %{
        id: "id-a",
        name: "A",
        description: ""
      })

      assert {:ok, %{name: "a"}} = Mounts.mount_for("mounts/a/X.md")
      assert {:error, :not_in_mount} = Mounts.mount_for("sources/x")
    end

    test "every entry errors :no_workspace when none is open" do
      Manager.close()
      assert {:error, :no_workspace} = Mounts.list()
      assert {:error, :no_workspace} = Mounts.enabled()
      assert {:error, :no_workspace} = Mounts.mount_for("mounts/a/x.md")
      assert {:error, :no_workspace} = Mounts.set_enabled("a", true)
    end
  end
end
