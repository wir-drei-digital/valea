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

    test "a directory basename with a control character is degraded even with a valid manifest",
         %{root: root} do
      # A stray newline in the directory basename — plant a PERFECTLY VALID
      # manifest inside it, to prove the guard fires on the basename alone,
      # not on manifest content (mirroring `c`'s manifest-driven degrade
      # above, this is the basename-driven degrade).
      dir = mount_dir(root, "evil\nname")
      write_manifest!(dir, %{id: "id-evil", name: "Evil", description: ""})

      [m] = Mounts.list(root)

      assert m.degraded == "invalid mount directory name"
      assert m.manifest == nil
      assert m.name == "evil\nname"
      # rel_root must never carry the raw control character through to a
      # renderer (MountsMd's "Needs attention" line interpolates it RAW) —
      # see the moduledoc on `Valea.Mounts`.
      refute String.contains?(m.rel_root, "\n")
      # never in the effective set, regardless of the config `enabled` flag.
      assert Mounts.enabled(root) == []
    end

    test "a directory basename with a DEL byte is degraded", %{root: root} do
      dir = mount_dir(root, "evil\x7Fname")
      write_manifest!(dir, %{id: "id-evil2", name: "Evil2", description: ""})

      [m] = Mounts.list(root)
      assert m.degraded == "invalid mount directory name"
      assert Mounts.enabled(root) == []
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

  describe "list/1 & enabled/1 — merges declared external mounts" do
    setup do
      %{root: tmp_dir!("valea-mounts-merge")}
    end

    test "one embedded + one external declared mount both appear in enabled/1", %{root: root} do
      write_manifest!(mount_dir(root, "a"), %{id: "id-a", name: "A", description: ""})
      ext = tmp_dir!("valea-mounts-ext")
      write_manifest!(ext, %{id: "ext-id", name: "Ext", description: ""})

      write_workspace_yaml!(root, """
      mounts:
        outside:
          kind: path
          ref: "#{ext}"
      """)

      names = root |> Mounts.enabled() |> Enum.map(& &1.name)
      assert names == ["a", "outside"]

      list_names = root |> Mounts.list() |> Enum.map(& &1.name)
      assert list_names == ["a", "outside"]
    end

    test "an external mount's enabled default is true when its config entry omits enabled", %{
      root: root
    } do
      ext = tmp_dir!("valea-mounts-ext")
      write_manifest!(ext, %{id: "ext-id", name: "Ext", description: ""})

      write_workspace_yaml!(root, """
      mounts:
        outside:
          kind: path
          ref: "#{ext}"
      """)

      [outside] = root |> Mounts.list() |> Enum.filter(&(&1.name == "outside"))
      assert outside.enabled == true
    end

    test "disabling the external name (via config) drops it from enabled/1 but list/1 keeps it",
         %{root: root} do
      ext = tmp_dir!("valea-mounts-ext")
      write_manifest!(ext, %{id: "ext-id", name: "Ext", description: ""})

      write_workspace_yaml!(root, """
      mounts:
        outside:
          kind: path
          ref: "#{ext}"
          enabled: false
      """)

      enabled_names = root |> Mounts.enabled() |> Enum.map(& &1.name)
      refute "outside" in enabled_names

      list = Mounts.list(root)
      outside = Enum.find(list, &(&1.name == "outside"))
      assert outside.enabled == false
      assert outside.degraded == nil
    end

    test "embedded/external name collision degrades BOTH entries and excludes both from enabled/1",
         %{root: root} do
      write_manifest!(mount_dir(root, "dup"), %{id: "id-dup", name: "Dup", description: ""})
      ext = tmp_dir!("valea-mounts-ext")
      write_manifest!(ext, %{id: "ext-dup", name: "ExtDup", description: ""})

      write_workspace_yaml!(root, """
      mounts:
        dup:
          kind: path
          ref: "#{ext}"
      """)

      list = Mounts.list(root)
      dups = Enum.filter(list, &(&1.name == "dup"))
      assert length(dups) == 2

      assert Enum.all?(
               dups,
               &(&1.degraded == "name used by both an embedded and an external mount")
             )

      refute "dup" in (root |> Mounts.enabled() |> Enum.map(& &1.name))
    end

    test "a guardrail-degraded external mount is excluded from enabled/1 even with enabled: true",
         %{root: _root} do
      parent = tmp_dir!("valea-mounts-parent")
      ws = Path.join(parent, "the-workspace")
      File.mkdir_p!(ws)

      write_workspace_yaml!(ws, """
      mounts:
        evil:
          kind: path
          ref: "#{parent}"
          enabled: true
      """)

      list = Mounts.list(ws)
      [evil] = Enum.filter(list, &(&1.name == "evil"))
      assert evil.degraded =~ "ancestor"
      assert evil.enabled == true

      refute "evil" in (ws |> Mounts.enabled() |> Enum.map(& &1.name))
    end

    test "two workspaces declaring the same external ICM each resolve it independently, unshared state" do
      shared = tmp_dir!("valea-mounts-shared")
      write_manifest!(shared, %{id: "shared-id", name: "Shared", description: ""})

      ws1 = tmp_dir!("valea-mounts-ws1")
      ws2 = tmp_dir!("valea-mounts-ws2")

      write_workspace_yaml!(ws1, """
      mounts:
        shared:
          kind: path
          ref: "#{shared}"
      """)

      write_workspace_yaml!(ws2, """
      mounts:
        shared:
          kind: path
          ref: "#{shared}"
          enabled: false
      """)

      [m1] = Mounts.list(ws1) |> Enum.filter(&(&1.name == "shared"))
      [m2] = Mounts.list(ws2) |> Enum.filter(&(&1.name == "shared"))

      assert m1.root == m2.root
      assert m1.degraded == nil
      assert m2.degraded == nil
      # each workspace's `enabled:` overlay is independent -- no coordination.
      assert Enum.map(Mounts.enabled(ws1), & &1.name) == ["shared"]
      assert Enum.map(Mounts.enabled(ws2), & &1.name) == []
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

  describe "mount_for/2 — absolute paths (external mounts)" do
    setup do
      root = tmp_dir!("valea-mounts-abs")
      write_manifest!(mount_dir(root, "a"), %{id: "id-a", name: "A", description: ""})

      ext = tmp_dir!("valea-mounts-ext")
      write_manifest!(ext, %{id: "ext-id", name: "Ext", description: ""})
      File.mkdir_p!(Path.join(ext, "Offers"))
      File.write!(Path.join(ext, "Offers/X.md"), "# X")

      write_workspace_yaml!(root, """
      mounts:
        outside:
          kind: path
          ref: "#{ext}"
      """)

      [outside] = Mounts.list(root) |> Enum.filter(&(&1.name == "outside"))
      %{root: root, ext: ext, outside: outside}
    end

    test "resolves an absolute path under the external mount's real root", %{
      root: root,
      outside: outside
    } do
      path = Path.join(outside.root, "Offers/X.md")
      assert %{name: "outside"} = Mounts.mount_for(root, path)
    end

    test "an absolute path exactly equal to the external root resolves too", %{
      root: root,
      outside: outside
    } do
      assert %{name: "outside"} = Mounts.mount_for(root, outside.root)
    end

    test "a sibling path sharing a string prefix with the external root is not attributed (segment boundary)",
         %{root: root, outside: outside} do
      sibling = outside.root <> "-other/file.md"
      assert Mounts.mount_for(root, sibling) == nil
    end

    test "embedded rel-path attribution is unaffected by a declared external mount", %{
      root: root
    } do
      assert %{name: "a"} = Mounts.mount_for(root, "mounts/a/X.md")
    end

    test "an absolute path under a disabled external mount's root is not attributed", %{
      root: root,
      ext: ext
    } do
      write_workspace_yaml!(root, """
      mounts:
        outside:
          kind: path
          ref: "#{ext}"
          enabled: false
      """)

      [outside] = Mounts.list(root) |> Enum.filter(&(&1.name == "outside"))
      path = Path.join(outside.root, "Offers/X.md")

      assert Mounts.mount_for(root, path) == nil
    end

    test "an absolute path under a guardrail-degraded external mount's root is not attributed",
         %{root: _root} do
      parent = tmp_dir!("valea-mounts-parent")
      ws = Path.join(parent, "the-workspace")
      File.mkdir_p!(ws)

      write_workspace_yaml!(ws, """
      mounts:
        evil:
          kind: path
          ref: "#{parent}"
      """)

      [evil] = Mounts.list(ws) |> Enum.filter(&(&1.name == "evil"))
      assert evil.degraded != nil

      path = Path.join(evil.root, "somewhere/deep/file.md")
      assert Mounts.mount_for(ws, path) == nil
    end

    test "an absolute path outside any declared external root returns nil", %{root: root} do
      assert Mounts.mount_for(root, "/definitely/not/a/mount/path") == nil
    end

    test "a mounts/<name> rel path never attributes to an external-only name — embedded shape only",
         %{root: root, ext: ext} do
      # `ext` is declared as external mount "outside" (setup); there is no
      # embedded mounts/outside directory. The `mounts/<name>` rel-path
      # shape is the EMBEDDED addressing scheme — external content is
      # addressed by absolute path only.
      refute File.dir?(Path.join([root, "mounts", "outside"]))
      assert File.dir?(ext)

      assert Mounts.mount_for(root, "mounts/outside/Offers/X.md") == nil
    end

    test "nested external roots: most-specific root wins when the OUTER name sorts first" do
      %{ws: ws, inner: inner, outer: outer} = nested_external_ws!("a-outer", "z-inner")

      assert %{name: "z-inner"} = Mounts.mount_for(ws, Path.join(inner.root, "X.md"))
      # a path under outer but NOT under inner still attributes to outer.
      assert %{name: "a-outer"} = Mounts.mount_for(ws, Path.join(outer.root, "Y.md"))
    end

    test "nested external roots: most-specific root wins when the INNER name sorts first" do
      %{ws: ws, inner: inner, outer: outer} = nested_external_ws!("z-outer", "a-inner")

      assert %{name: "a-inner"} = Mounts.mount_for(ws, Path.join(inner.root, "X.md"))
      assert %{name: "z-outer"} = Mounts.mount_for(ws, Path.join(outer.root, "Y.md"))
    end
  end

  # Two effective external mounts, one root nested inside the other —
  # attribution for a path in the inner mount must pick the most-specific
  # (longest) root, never the first name alphabetically.
  defp nested_external_ws!(outer_name, inner_name) do
    outer = tmp_dir!("valea-mounts-outer")
    inner = Path.join(outer, "inner")
    write_manifest!(outer, %{id: "id-outer", name: "Outer", description: ""})
    write_manifest!(inner, %{id: "id-inner", name: "Inner", description: ""})
    File.write!(Path.join(inner, "X.md"), "# X")

    ws = tmp_dir!("valea-mounts-nested-ws")

    write_workspace_yaml!(ws, """
    mounts:
      #{outer_name}:
        kind: path
        ref: "#{outer}"
      #{inner_name}:
        kind: path
        ref: "#{inner}"
    """)

    [inner_mount] = Mounts.list(ws) |> Enum.filter(&(&1.name == inner_name))
    [outer_mount] = Mounts.list(ws) |> Enum.filter(&(&1.name == outer_name))
    assert inner_mount.degraded == nil
    assert outer_mount.degraded == nil
    %{ws: ws, inner: inner_mount, outer: outer_mount}
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

    test "sets enabled for an external-only name with no mounts/<name> dir on disk, preserving kind/ref",
         %{ws: ws} do
      config_path = Path.join(ws.path, "config/workspace.yaml")
      {:ok, %{"id" => id}} = YamlElixir.read_from_file(config_path)

      File.write!(config_path, """
      version: 4
      id: #{id}
      mounts:
        outside:
          kind: path
          ref: "/some/external/ref"
      """)

      refute File.dir?(Path.join([ws.path, "mounts", "outside"]))

      assert :ok = Mounts.set_enabled("outside", false)

      {:ok, doc} = YamlElixir.read_from_file(config_path)
      assert doc["id"] == id
      assert doc["mounts"]["outside"]["enabled"] == false
      assert doc["mounts"]["outside"]["kind"] == "path"
      assert doc["mounts"]["outside"]["ref"] == "/some/external/ref"
      refute File.dir?(Path.join([ws.path, "mounts", "outside"]))
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

    test "rejects a name containing a control character" do
      assert {:error, _} = Mounts.set_enabled("evil\nname", true)
    end

    test "rejects a name containing a DEL byte" do
      assert {:error, _} = Mounts.set_enabled("evil\x7Fname", true)
    end
  end

  describe "declare_external/3" do
    setup do
      %{root: tmp_dir!("valea-mounts-declare")}
    end

    test "happy path: declares an external mount, preserving other entries + version/id", %{
      root: root
    } do
      ext = tmp_dir!("valea-mounts-declare-ext")
      write_manifest!(ext, %{id: "ext-id", name: "Ext", description: ""})

      write_workspace_yaml!(root, """
      version: 4
      id: ws-id
      mounts:
        keep:
          enabled: false
      """)

      assert {:ok, resolved} = Mounts.declare_external(root, "outside", ext)
      assert File.dir?(resolved)

      {:ok, doc} = YamlElixir.read_from_file(Path.join(root, "config/workspace.yaml"))
      assert doc["version"] == 4
      assert doc["id"] == "ws-id"
      assert doc["mounts"]["keep"]["enabled"] == false
      assert doc["mounts"]["outside"]["kind"] == "path"
      assert doc["mounts"]["outside"]["ref"] == ext
      assert doc["mounts"]["outside"]["enabled"] == true

      [outside] = root |> Mounts.list() |> Enum.filter(&(&1.name == "outside"))
      assert outside.rel_root == nil
      assert outside.degraded == nil
      assert outside.root == resolved
      assert outside.manifest.name == "Ext"
    end

    # Mirrors `Valea.Mounts.ExternalTest`'s own "~ expansion" fixture: a
    # real, uniquely-named, self-cleaning directory planted directly under
    # the ACTUAL $HOME (there is no other way to exercise `~` — it resolves
    # against `System.user_home!/0` inside the running node, not a
    # sandboxable value).
    test "preserves a ~-form ref exactly, not its resolved absolute path" do
      unique =
        "valea-mounts-declare-tilde-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"

      home_child = Path.join(System.user_home!(), unique)
      on_exit(fn -> File.rm_rf!(home_child) end)
      write_manifest!(home_child, %{id: "tilde-id", name: "Tilde", description: ""})

      root = tmp_dir!("valea-mounts-declare-tilde-ws")
      write_workspace_yaml!(root, "mounts: {}\n")
      ref = "~/#{unique}"

      assert {:ok, resolved} = Mounts.declare_external(root, "tilde", ref)
      assert File.dir?(resolved)
      refute resolved == ref

      {:ok, doc} = YamlElixir.read_from_file(Path.join(root, "config/workspace.yaml"))
      assert doc["mounts"]["tilde"]["ref"] == ref
    end

    test "an invalid ref is rejected with validate_ref's own reason and never touches config", %{
      root: root
    } do
      write_workspace_yaml!(root, """
      version: 1
      id: ws-id
      mounts: {}
      """)

      before = File.read!(Path.join(root, "config/workspace.yaml"))

      # `root` itself as the ref -- points at (== IS) the workspace root.
      assert {:error, :inside_workspace} = Mounts.declare_external(root, "bad", root)

      assert File.read!(Path.join(root, "config/workspace.yaml")) == before
    end

    test "rejects an invalid mount name before ever touching validate_ref or config", %{
      root: root
    } do
      refute File.exists?(Path.join(root, "config/workspace.yaml"))

      assert {:error, :invalid_mount_name} = Mounts.declare_external(root, "a/b", root)

      refute File.exists?(Path.join(root, "config/workspace.yaml"))
    end

    test "re-declaring an existing name overwrites kind/ref/enabled, preserving other entries", %{
      root: root
    } do
      ext1 = tmp_dir!("valea-mounts-declare-ext1")
      write_manifest!(ext1, %{id: "ext1-id", name: "Ext1", description: ""})
      ext2 = tmp_dir!("valea-mounts-declare-ext2")
      write_manifest!(ext2, %{id: "ext2-id", name: "Ext2", description: ""})

      write_workspace_yaml!(root, """
      mounts:
        keep:
          enabled: false
      """)

      assert {:ok, _resolved1} = Mounts.declare_external(root, "outside", ext1)
      assert {:ok, resolved2} = Mounts.declare_external(root, "outside", ext2)

      {:ok, doc} = YamlElixir.read_from_file(Path.join(root, "config/workspace.yaml"))
      assert doc["mounts"]["outside"]["ref"] == ext2
      assert doc["mounts"]["keep"]["enabled"] == false

      [outside] = root |> Mounts.list() |> Enum.filter(&(&1.name == "outside"))
      assert outside.root == resolved2
      assert outside.manifest.name == "Ext2"
    end
  end

  describe "undeclare/2" do
    setup do
      %{root: tmp_dir!("valea-mounts-undeclare")}
    end

    test "removes an external entry only, preserving other entries + version/id", %{root: root} do
      ext = tmp_dir!("valea-mounts-undeclare-ext")
      write_manifest!(ext, %{id: "ext-id", name: "Ext", description: ""})

      write_workspace_yaml!(root, """
      version: 4
      id: ws-id
      mounts:
        keep:
          enabled: false
        outside:
          kind: path
          ref: "#{ext}"
      """)

      [outside] = root |> Mounts.list() |> Enum.filter(&(&1.name == "outside"))

      assert {:ok, resolved} = Mounts.undeclare(root, "outside")
      assert resolved == outside.root

      {:ok, doc} = YamlElixir.read_from_file(Path.join(root, "config/workspace.yaml"))
      assert doc["version"] == 4
      assert doc["id"] == "ws-id"
      assert doc["mounts"]["keep"]["enabled"] == false
      refute Map.has_key?(doc["mounts"], "outside")

      refute "outside" in (root |> Mounts.list() |> Enum.map(& &1.name))
    end

    test "leaves the referenced external folder untouched on disk", %{root: root} do
      ext = tmp_dir!("valea-mounts-undeclare-ext2")
      write_manifest!(ext, %{id: "ext-id", name: "Ext", description: ""})

      write_workspace_yaml!(root, """
      mounts:
        outside:
          kind: path
          ref: "#{ext}"
      """)

      assert {:ok, _path} = Mounts.undeclare(root, "outside")

      assert File.dir?(ext)
      assert File.exists?(Path.join(ext, "icm.yaml"))
    end

    test "an embedded mount's directory is left untouched -- errors instead of removing anything",
         %{root: root} do
      write_manifest!(mount_dir(root, "embedded"), %{
        id: "id-e",
        name: "Embedded",
        description: ""
      })

      assert {:error, :mount_not_declared} = Mounts.undeclare(root, "embedded")

      assert File.dir?(mount_dir(root, "embedded"))
      assert File.exists?(Path.join(mount_dir(root, "embedded"), "icm.yaml"))
    end

    test "errors :mount_not_declared for a name with no config entry at all", %{root: root} do
      write_workspace_yaml!(root, "mounts: {}\n")
      assert {:error, :mount_not_declared} = Mounts.undeclare(root, "ghost")
    end

    test "errors :mount_not_declared for a name whose config entry has no kind: path (an embedded-only relational entry)",
         %{root: root} do
      write_workspace_yaml!(root, """
      mounts:
        half:
          enabled: false
      """)

      before = File.read!(Path.join(root, "config/workspace.yaml"))

      assert {:error, :mount_not_declared} = Mounts.undeclare(root, "half")

      assert File.read!(Path.join(root, "config/workspace.yaml")) == before
    end

    test "rejects an invalid mount name", %{root: root} do
      assert {:error, :invalid_mount_name} = Mounts.undeclare(root, "a/b")
    end
  end

  describe "declare_external/3, undeclare/2, set_enabled/2 -- audit (current workspace)" do
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

    test "declare_external audits mount_declared with name and resolved path", %{ws: ws} do
      ext = tmp_dir!("valea-mounts-audit-declare-ext")
      write_manifest!(ext, %{id: "ext-id", name: "Ext", description: ""})

      assert {:ok, resolved} = Mounts.declare_external(ws.path, "outside", ext)

      {:ok, entries} = Valea.Audit.entries(10)
      entry = Enum.find(entries, &(&1["type"] == "mount_declared"))
      assert entry["name"] == "outside"
      assert entry["path"] == resolved
    end

    test "undeclare audits mount_undeclared with name and resolved path", %{ws: ws} do
      ext = tmp_dir!("valea-mounts-audit-undeclare-ext")
      write_manifest!(ext, %{id: "ext-id", name: "Ext", description: ""})
      {:ok, resolved} = Mounts.declare_external(ws.path, "outside", ext)

      assert {:ok, ^resolved} = Mounts.undeclare(ws.path, "outside")

      {:ok, entries} = Valea.Audit.entries(10)
      entry = Enum.find(entries, &(&1["type"] == "mount_undeclared"))
      assert entry["name"] == "outside"
      assert entry["path"] == resolved
    end

    test "set_enabled audits mount_disabled/mount_enabled for an EXTERNAL mount, with resolved path",
         %{ws: ws} do
      ext = tmp_dir!("valea-mounts-audit-toggle-ext")
      write_manifest!(ext, %{id: "ext-id", name: "Ext", description: ""})
      {:ok, resolved} = Mounts.declare_external(ws.path, "outside", ext)

      assert :ok = Mounts.set_enabled("outside", false)

      {:ok, entries} = Valea.Audit.entries(10)
      disabled = Enum.find(entries, &(&1["type"] == "mount_disabled"))
      assert disabled["name"] == "outside"
      assert disabled["path"] == resolved

      assert :ok = Mounts.set_enabled("outside", true)

      {:ok, entries2} = Valea.Audit.entries(10)
      enabled = Enum.find(entries2, &(&1["type"] == "mount_enabled"))
      assert enabled["name"] == "outside"
      assert enabled["path"] == resolved
    end

    test "set_enabled does NOT audit an EMBEDDED mount toggle", %{ws: ws} do
      write_manifest!(Path.join([ws.path, "mounts", "emb"]), %{
        id: "id-e",
        name: "Emb",
        description: ""
      })

      assert :ok = Mounts.set_enabled("emb", false)

      {:ok, entries} = Valea.Audit.entries(50)
      refute Enum.any?(entries, &(&1["type"] in ["mount_enabled", "mount_disabled"]))
    end
  end

  describe "create/3" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "valea-mounts-create-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "scaffolds a new mount: manifest, AGENTS.md, CLAUDE.md, discoverable via list/1", %{
      root: root
    } do
      assert {:ok, mount} = Mounts.create(root, "Mara Lindt Coaching", "A coaching business")

      assert mount.name == "mara-lindt-coaching"
      assert mount.rel_root == "mounts/mara-lindt-coaching"
      assert mount.degraded == nil
      assert mount.enabled == true

      assert %Manifest{name: "Mara Lindt Coaching", description: "A coaching business"} =
               mount.manifest

      dir = Path.join([root, "mounts", "mara-lindt-coaching"])
      assert File.dir?(dir)
      assert File.exists?(Path.join(dir, "icm.yaml"))
      assert File.read!(Path.join(dir, "CLAUDE.md")) == "@AGENTS.md\n"

      agents_md = File.read!(Path.join(dir, "AGENTS.md"))
      assert agents_md =~ "Mara Lindt Coaching"
      assert agents_md =~ "A coaching business"

      # discoverable via list/1, non-degraded, and shown effective.
      assert [listed] = Mounts.list(root)
      assert listed.name == "mara-lindt-coaching"
      assert root |> Mounts.enabled() |> Enum.map(& &1.name) == ["mara-lindt-coaching"]
    end

    test "the manifest's name is the GIVEN name, not the slug", %{root: root} do
      assert {:ok, mount} = Mounts.create(root, "Sales & Co.", "")
      assert mount.manifest.name == "Sales & Co."
      assert mount.name == "sales-co"
    end

    test "an empty description is preserved as an empty string, not a placeholder", %{root: root} do
      assert {:ok, mount} = Mounts.create(root, "Empty Desc", "")
      assert mount.manifest.description == ""
    end

    test "rejects when the slugged directory already exists", %{root: root} do
      assert {:ok, _} = Mounts.create(root, "Same Name", "first")
      assert {:error, :already_exists} = Mounts.create(root, "Same Name", "second")
    end

    test "rejects an empty name" do
      assert {:error, _} = Mounts.create(System.tmp_dir!(), "", "desc")
    end

    test "rejects an all-whitespace name (would mint an instantly-degraded manifest)" do
      assert {:error, :invalid_mount_name} = Mounts.create(System.tmp_dir!(), "   ", "desc")
    end

    test "rejects a name containing a control character" do
      assert {:error, _} = Mounts.create(System.tmp_dir!(), "evil\nname", "desc")
    end

    test "rejects a name containing a DEL byte" do
      assert {:error, _} = Mounts.create(System.tmp_dir!(), "evil\x7Fname", "desc")
    end

    test "accepts a display name containing a path separator (slug strips it)", %{root: root} do
      # "Sales/Marketing" is a legitimate BUSINESS name — the display name
      # only flows into `Scaffold.slugify/1` (directory basename, strips to
      # [a-z0-9-]) and `Manifest.render/1` (Yaml.escape'd), so a `/` never
      # reaches the filesystem as a separator. Only `set_enabled/2` (whose
      # name IS a directory basename) keeps the strict basename validator.
      assert {:ok, mount} = Mounts.create(root, "Sales/Marketing", "cross-team")

      assert mount.name == "sales-marketing"
      assert mount.rel_root == "mounts/sales-marketing"
      assert mount.manifest.name == "Sales/Marketing"
      assert File.dir?(Path.join([root, "mounts", "sales-marketing"]))
    end

    test "accepts a display name containing ..", %{root: root} do
      assert {:ok, mount} = Mounts.create(root, "Ops (EU/APAC)..", "regional ops")
      assert mount.name == "ops-eu-apac"
      assert mount.manifest.name == "Ops (EU/APAC).."
    end

    test "does not touch config/workspace.yaml or regenerate MOUNTS.md (caller's job)", %{
      root: root
    } do
      refute File.exists?(Path.join(root, "config/workspace.yaml"))
      assert {:ok, _} = Mounts.create(root, "No Side Effects", "desc")
      refute File.exists?(Path.join(root, "config/workspace.yaml"))
      refute File.exists?(Path.join(root, "MOUNTS.md"))
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
