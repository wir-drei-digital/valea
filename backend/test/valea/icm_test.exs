defmodule Valea.ICMTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager
  alias Valea.ICM

  defp write_mount!(ws_path, name, title) do
    dir = Path.join([ws_path, "mounts", name])
    File.mkdir_p!(dir)
    Manifest.write!(dir, %{id: "id-" <> name, name: title, description: ""})
  end

  # Declares an external (kind: "path") mount in the workspace's existing
  # config/workspace.yaml, preserving version/id and every existing mount
  # entry.
  defp declare_external!(ws_path, name, ref) do
    config_path = Path.join(ws_path, "config/workspace.yaml")
    {:ok, doc} = YamlElixir.read_from_file(config_path)

    mounts = Map.put(Map.get(doc, "mounts") || %{}, name, %{"kind" => "path", "ref" => ref})

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
        "valea-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Manifest.write!(dir, %{id: "ext-id", name: name, description: ""})
    dir
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    # A fresh scaffold (T8) mints its own real mount from the template's rich
    # seed content (Offers/, Workflows/, etc.) at `mounts/<slug-of-name>` —
    # naming the workspace "Primary" lands that mount at exactly
    # `mounts/primary`, the name/title this whole suite asserts against, with
    # no separate copy/seed step needed.
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{ws: ws.path}
  end

  test "tree lists seeded folders with counts, grouped by mount" do
    {:ok, [mount]} = ICM.tree()
    assert mount.mount == "primary"
    assert mount.title == "Primary"
    assert mount.root_rel == "mounts/primary"

    names = Enum.map(mount.tree, & &1.name)
    assert "Offers" in names
    assert "Tone & Voice" in names
    offers = Enum.find(mount.tree, &(&1.name == "Offers"))
    assert offers.type == :folder
    assert offers.path == "mounts/primary/Offers"
    assert offers.page_count == 2
    child = Enum.find(offers.children, &(&1.name == "Founder Coaching Package"))
    assert child
    assert child.path == "mounts/primary/Offers/Founder Coaching Package.md"
    assert child.uri == "icm://mounts/primary/Offers/Founder Coaching Package.md"
  end

  test "tree lists non-.md files as :file leaves with a lowercase ext, still excluding hidden files",
       %{ws: ws} do
    dir = Path.join(ws, "mounts/primary/Offers")
    File.write!(Path.join(dir, "X.pdf"), "%PDF-1.4 fake")
    File.write!(Path.join(dir, "logo.PNG"), "not really a png")
    File.write!(Path.join(dir, ".hidden.pdf"), "still hidden")

    {:ok, [mount]} = ICM.tree()
    offers = Enum.find(mount.tree, &(&1.name == "Offers"))

    pdf = Enum.find(offers.children, &(&1.name == "X.pdf"))
    assert pdf == %{name: "X.pdf", path: "mounts/primary/Offers/X.pdf", type: :file, ext: ".pdf"}

    png = Enum.find(offers.children, &(&1.name == "logo.PNG"))

    assert png == %{
             name: "logo.PNG",
             path: "mounts/primary/Offers/logo.PNG",
             type: :file,
             ext: ".png"
           }

    refute Enum.any?(offers.children, &String.starts_with?(&1.name, "."))

    # file leaves never count as pages
    assert offers.page_count == 2

    # the mount's own manifest is infrastructure, not knowledge content —
    # never listed at the mount root
    refute Enum.any?(mount.tree, &(&1.name == "icm.yaml"))
  end

  test "external mounts are surfaced in tree/0 with the absolute physical root/paths (A2-T5b), alongside embedded groups",
       %{ws: ws} do
    ext = external_icm!("Ext")
    File.mkdir_p!(Path.join(ext, "Offers"))
    File.write!(Path.join(ext, "Offers/X.md"), "# X\n")
    declare_external!(ws, "ext", ext)

    # Derive assertions from the EFFECTIVE mount's realpath-resolved root
    # (m.root), not the raw tmp path — on macOS the raw `/var/folders/...`
    # tmp path never string-matches the resolved `/private/var/...` root.
    [ext_mount] = Enum.filter(Mounts.enabled(ws), &(&1.name == "ext"))

    assert {:ok, groups} = ICM.tree()
    assert Enum.map(groups, & &1.mount) |> Enum.sort() == ["ext", "primary"]

    ext_group = Enum.find(groups, &(&1.mount == "ext"))
    assert ext_group.title == "Ext"
    # root_rel stays a string (the RPC type holds), but for an external mount
    # its value is the ABSOLUTE physical root — the one vocabulary this
    # group's node paths use (binding semantic 1).
    assert ext_group.root_rel == ext_mount.root

    offers = Enum.find(ext_group.tree, &(&1.name == "Offers"))
    assert offers.type == :folder
    assert offers.path == Path.join(ext_mount.root, "Offers")
    assert offers.page_count == 1

    x = Enum.find(offers.children, &(&1.name == "X"))
    assert x.type == :page
    assert x.path == Path.join(ext_mount.root, "Offers/X.md")
    assert x.uri == "icm://" <> Path.join(ext_mount.root, "Offers/X.md")

    # Embedded groups are unchanged: still workspace-relative.
    primary = Enum.find(groups, &(&1.mount == "primary"))
    assert primary.root_rel == "mounts/primary"
  end

  test "a DISABLED external mount drops out of tree/0 entirely", %{ws: ws} do
    ext = external_icm!("Ext")
    declare_external!(ws, "ext", ext)
    :ok = Mounts.set_enabled("ext", false)

    assert {:ok, groups} = ICM.tree()
    assert Enum.map(groups, & &1.mount) == ["primary"]
  end

  test "page reads content with title and uri" do
    {:ok, page} = ICM.page("mounts/primary/Offers/Founder Coaching Package.md")
    assert page.title == "Founder Coaching Package"
    assert page.uri == "icm://mounts/primary/Offers/Founder Coaching Package.md"
    assert page.content =~ "## Best fit"
  end

  test "page rejects escape attempts" do
    assert {:error, :outside_workspace} = ICM.page("../logs/audit.jsonl")
    assert {:error, :outside_workspace} = ICM.page("Offers/../../secrets/x")
    assert {:error, :outside_workspace} = ICM.page("mounts/primary/../../logs/audit.jsonl")
  end

  test "page returns not_found for a missing page" do
    assert {:error, :not_found} = ICM.page("mounts/primary/Offers/Nope.md")
  end

  test "errors without a workspace" do
    Manager.close()
    assert {:error, :no_workspace} = ICM.tree()
    assert {:error, :no_workspace} = ICM.page("mounts/primary/Offers/Founder Coaching Package.md")
  end

  describe "multiple mounts" do
    setup %{ws: ws} do
      write_mount!(ws, "a", "Mount A")
      File.write!(Path.join([ws, "mounts", "a", "Notes.md"]), "# A Note\n")

      write_mount!(ws, "b", "Mount B")
      File.write!(Path.join([ws, "mounts", "b", "Secret.md"]), "# B Secret\n")
      :ok = Mounts.set_enabled("b", false)

      :ok
    end

    test "tree/0 returns one entry per ENABLED mount, with workspace-relative node paths" do
      {:ok, mounts} = ICM.tree()
      assert Enum.map(mounts, & &1.mount) |> Enum.sort() == ["a", "primary"]
      refute Enum.any?(mounts, &(&1.mount == "b"))

      a = Enum.find(mounts, &(&1.mount == "a"))
      assert a.title == "Mount A"
      assert a.root_rel == "mounts/a"
      assert [%{path: "mounts/a/Notes.md", type: :page, uri: "icm://mounts/a/Notes.md"}] = a.tree
    end

    test "page reads a specific mount's file by its full workspace-relative path" do
      assert {:ok, page} = ICM.page("mounts/a/Notes.md")
      assert page.content == "# A Note\n"
      assert page.uri == "icm://mounts/a/Notes.md"
    end

    test "page reads a DISABLED mount's page fine — enabled-gating is a read_roots/agent concern, not the editor's" do
      assert {:ok, page} = ICM.page("mounts/b/Secret.md")
      assert page.content == "# B Secret\n"
    end

    test "a `..` escape cannot cross from one mount into another" do
      assert {:error, :outside_workspace} = ICM.page("mounts/a/../b/Secret.md")
    end

    test "create/rename/delete operate within the resolving mount's own containment", %{ws: ws} do
      assert {:ok, %{path: "mounts/a/New.md"}} = ICM.create_page("mounts/a", "New")
      assert {:ok, %{path: "mounts/a/Sub"}} = ICM.create_folder("mounts/a", "Sub")

      assert {:ok, %{path: "mounts/a/Renamed.md"}} = ICM.rename("mounts/a/New.md", "Renamed")

      assert {:ok, %{deleted: true}} = ICM.delete("mounts/a/Renamed.md")
      refute File.exists?(Path.join(ws, "mounts/a/Renamed.md"))

      # Escaping mount a's own root while creating is denied, even though
      # mount "b" is a real, discovered mount.
      assert {:error, :outside_workspace} = ICM.create_page("mounts/a/../b", "Intruder")
    end
  end

  describe "external mounts" do
    setup %{ws: ws} do
      ext = external_icm!("Ext")
      File.mkdir_p!(Path.join(ext, "Offers"))
      File.write!(Path.join(ext, "Offers/External.md"), "# External Page\n")
      declare_external!(ws, "ext", ext)

      %{ws: ws, ext: ext}
    end

    test "external mounts are editable via ICM ops through their absolute physical paths (A2-T5b)",
         %{ws: ws} do
      # Sanity: the external mount IS effective.
      [m] = Enum.filter(Mounts.enabled(ws), &(&1.name == "ext"))
      assert m.rel_root == nil

      # Derive the page path from the EFFECTIVE mount's realpath-RESOLVED root
      # (`m.root`), not the raw tmp path — on macOS the raw `/var/folders/...`
      # tmp path never string-matches the resolved `/private/var/...` root.
      ext_page_abs = Path.join(m.root, "Offers/External.md")
      assert File.exists?(ext_page_abs)
      assert {:ok, %{name: "ext", rel_root: nil}} = Mounts.mount_for(ext_page_abs)

      # page/1 reads the external page fine, by its absolute physical path —
      # `path`/`uri` round-trip that same absolute vocabulary.
      assert {:ok, page} = ICM.page(ext_page_abs)
      assert page.path == ext_page_abs
      assert page.content == "# External Page\n"
      assert page.uri == "icm://" <> ext_page_abs

      # create_page/2 + create_folder/2 land directly at the external mount's
      # own root (the same "" mount-relative special case embedded mounts get).
      assert {:ok, %{path: new_page_path}} = ICM.create_page(m.root, "New External")
      assert new_page_path == Path.join(m.root, "New External.md")
      assert File.exists?(new_page_path)

      assert {:ok, %{path: new_folder_path}} = ICM.create_folder(m.root, "New Folder")
      assert new_folder_path == Path.join(m.root, "New Folder")
      assert File.dir?(new_folder_path)

      # rename/2 works within the external mount.
      assert {:ok, %{path: renamed_path}} = ICM.rename(new_page_path, "Renamed External")
      assert renamed_path == Path.join(m.root, "Renamed External.md")
      refute File.exists?(new_page_path)
      assert File.exists?(renamed_path)

      # delete/1 of a page INSIDE the external mount is a legitimate
      # user-initiated editor action (binding semantic 7).
      assert {:ok, %{deleted: true}} = ICM.delete(renamed_path)
      refute File.exists?(renamed_path)

      # But never the mount root itself — Valea never deletes/moves an
      # external folder wholesale.
      assert {:error, :outside_workspace} = ICM.rename(m.root, "Hijacked")
      assert {:error, :outside_workspace} = ICM.delete(m.root)
      assert File.dir?(m.root), "mount root must remain untouched on disk"
    end

    test "a DISABLED external mount's absolute paths still get :outside_workspace from every editor op",
         %{ws: ws} do
      :ok = Mounts.set_enabled("ext", false)
      [m] = Enum.filter(Mounts.list(ws), &(&1.name == "ext"))
      ext_page_abs = Path.join(m.root, "Offers/External.md")

      # Sanity: disabled external no longer attributes via absolute path.
      assert {:error, :not_in_mount} = Mounts.mount_for(ext_page_abs)

      assert {:error, :outside_workspace} = ICM.page(ext_page_abs)
      assert {:error, :outside_workspace} = ICM.rename(ext_page_abs, "Renamed")
      assert {:error, :outside_workspace} = ICM.delete(ext_page_abs)
      assert File.exists?(ext_page_abs), "disabled external mount's file must be untouched"
    end
  end
end
