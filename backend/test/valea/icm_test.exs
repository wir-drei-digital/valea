defmodule Valea.ICMTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager
  alias Valea.ICM

  defp external_icm!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Manifest.write!(dir, %{id: Ecto.UUID.generate(), name: name, description: ""})
    dir
  end

  # `Valea.Mounts.list/1` is config truth over `icms:` only — a fresh v5
  # workspace seeds no mount at all. This whole suite's fixtures assume the
  # old starter mount's rich seed content (Offers/, Policies/, Pricing/,
  # Templates/, Clients/, Tone & Voice/, Workflows/, Decisions/), preserved
  # under `test/fixtures/starter_icm/` (Task 11.3), so it's copied fresh
  # into an EXTERNAL tmp dir and mounted via `Mounts.mount/2`, landing at
  # mount key "primary" (name "Primary" slugifies to "primary" —
  # `Valea.Workspace.Scaffold.slugify/1`).
  #
  # Task 4.2 re-key: every `Valea.ICM` function now takes `(mount_key,
  # rel_path)` where `rel_path` is relative to that ICM's OWN root — never
  # an absolute `icm.root`-joined literal, never a `mounts/<name>/...`
  # workspace-relative one. `""` addresses the mount's own root itself
  # (used where the old suite passed `icm.root` bare, e.g. as a
  # create-parent or a rename/delete target that must be rejected).
  defp mount_starter_icm!(workspace, name \\ "Primary") do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-starter-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.cp_r!(Path.expand("../fixtures/starter_icm", __DIR__), dir)

    on_exit(fn -> File.rm_rf!(dir) end)
    Manifest.write!(dir, %{id: Ecto.UUID.generate(), name: name, description: ""})

    {:ok, %{mount_key: mount_key, id: id}} = Mounts.mount(workspace, dir)
    %{mount_key: mount_key, id: id, root: Mounts.mount_by_key(workspace, mount_key).root}
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create("Primary")
    icm = mount_starter_icm!(ws.path)

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{ws: ws.path, icm: icm}
  end

  test "tree_for lists seeded folders with counts, ICM-relative paths", %{icm: icm} do
    {:ok, tree} = ICM.tree_for(icm.mount_key)
    assert tree.mount_key == icm.mount_key
    assert tree.title == "Primary"

    names = Enum.map(tree.tree, & &1.name)
    assert "Offers" in names
    assert "Tone & Voice" in names
    offers = Enum.find(tree.tree, &(&1.name == "Offers"))
    assert offers.type == :folder
    assert offers.path == "Offers"
    assert offers.page_count == 2
    child = Enum.find(offers.children, &(&1.name == "Founder Coaching Package"))
    assert child
    assert child.path == "Offers/Founder Coaching Package.md"
    assert child.uri == "icm://Offers/Founder Coaching Package.md"
  end

  test "tree_for lists non-.md files as :file leaves with a lowercase ext, still excluding hidden files",
       %{icm: icm} do
    dir = Path.join(icm.root, "Offers")
    File.write!(Path.join(dir, "X.pdf"), "%PDF-1.4 fake")
    File.write!(Path.join(dir, "logo.PNG"), "not really a png")
    File.write!(Path.join(dir, ".hidden.pdf"), "still hidden")

    {:ok, tree} = ICM.tree_for(icm.mount_key)
    offers = Enum.find(tree.tree, &(&1.name == "Offers"))

    pdf = Enum.find(offers.children, &(&1.name == "X.pdf"))

    assert pdf == %{
             name: "X.pdf",
             path: "Offers/X.pdf",
             type: :file,
             ext: ".pdf"
           }

    png = Enum.find(offers.children, &(&1.name == "logo.PNG"))

    assert png == %{
             name: "logo.PNG",
             path: "Offers/logo.PNG",
             type: :file,
             ext: ".png"
           }

    refute Enum.any?(offers.children, &String.starts_with?(&1.name, "."))

    # file leaves never count as pages
    assert offers.page_count == 2

    # the mount's own manifest is infrastructure, not knowledge content —
    # never listed at the mount root
    refute Enum.any?(tree.tree, &(&1.name == "icm.yaml"))
  end

  test "tree_for is scoped to the one mount named — a second mount's tree is fetched separately",
       %{ws: ws, icm: icm} do
    ext = external_icm!("Ext")
    File.mkdir_p!(Path.join(ext, "Offers"))
    File.write!(Path.join(ext, "Offers/X.md"), "# X\n")
    {:ok, %{mount_key: ext_key}} = Mounts.mount(ws, ext)

    assert {:ok, ext_tree} = ICM.tree_for(ext_key)
    assert ext_tree.title == "Ext"

    offers = Enum.find(ext_tree.tree, &(&1.name == "Offers"))
    assert offers.type == :folder
    assert offers.path == "Offers"
    assert offers.page_count == 1

    x = Enum.find(offers.children, &(&1.name == "X"))
    assert x.type == :page
    assert x.path == "Offers/X.md"
    assert x.uri == "icm://Offers/X.md"

    # The workspace's own "primary" mount is unaffected — a wholly separate
    # `tree_for/1` call.
    assert {:ok, primary_tree} = ICM.tree_for(icm.mount_key)
    assert primary_tree.title == "Primary"
  end

  test "tree_for a DISABLED mount returns :outside_workspace", %{ws: ws} do
    ext = external_icm!("Ext")
    {:ok, %{mount_key: ext_key}} = Mounts.mount(ws, ext)
    :ok = Mounts.set_enabled(ws, ext_key, false)

    assert {:error, :outside_workspace} = ICM.tree_for(ext_key)
  end

  test "tree_for an unknown mount key returns :outside_workspace", %{icm: _icm} do
    assert {:error, :outside_workspace} = ICM.tree_for("does-not-exist")
  end

  test "page reads content with title and uri", %{icm: icm} do
    {:ok, page} = ICM.page(icm.mount_key, "Offers/Founder Coaching Package.md")
    assert page.title == "Founder Coaching Package"
    assert page.uri == "icm://Offers/Founder Coaching Package.md"
    assert page.content =~ "## Best fit"
  end

  test "page rejects escape attempts", %{icm: icm} do
    assert {:error, :outside_workspace} = ICM.page(icm.mount_key, "../logs/audit.jsonl")
    assert {:error, :outside_workspace} = ICM.page(icm.mount_key, "Offers/../../secrets/x")
    assert {:error, :outside_workspace} = ICM.page(icm.mount_key, "../../logs/audit.jsonl")
  end

  test "page returns not_found for a missing page", %{icm: icm} do
    assert {:error, :not_found} = ICM.page(icm.mount_key, "Offers/Nope.md")
  end

  test "errors without a workspace", %{icm: icm} do
    mount_key = icm.mount_key
    Manager.close()
    assert {:error, :no_workspace} = ICM.tree_for(mount_key)
    assert {:error, :no_workspace} = ICM.page(mount_key, "Offers/Founder Coaching Package.md")
  end

  describe "multiple mounts" do
    setup %{ws: ws} do
      # Named "A"/"B" (not "Mount A"/"Mount B") so the auto-derived mount
      # key (`Valea.Workspace.Scaffold.slugify/1` of the manifest name)
      # lands at exactly "a"/"b" — the literal keys every assertion below
      # addresses.
      a = external_icm!("A")
      File.write!(Path.join(a, "Notes.md"), "# A Note\n")
      {:ok, %{mount_key: "a"}} = Mounts.mount(ws, a)

      b = external_icm!("B")
      File.write!(Path.join(b, "Secret.md"), "# B Secret\n")
      {:ok, %{mount_key: "b"}} = Mounts.mount(ws, b)
      :ok = Mounts.set_enabled(ws, "b", false)

      %{a_root: Mounts.mount_by_key(ws, "a").root, b_root: Mounts.mount_by_key(ws, "b").root}
    end

    test "tree_for(\"a\") lists its own content, ICM-relative" do
      {:ok, tree} = ICM.tree_for("a")
      assert tree.title == "A"
      assert [%{path: "Notes.md", type: :page, uri: "icm://Notes.md"}] = tree.tree
    end

    test "page reads a specific mount's file by (mount_key, rel_path)" do
      assert {:ok, page} = ICM.page("a", "Notes.md")
      assert page.content == "# A Note\n"
      assert page.uri == "icm://Notes.md"
    end

    # Was "page reads a DISABLED mount's page fine — enabled-gating is a
    # read_roots/agent concern, not the editor's" under the old EMBEDDED
    # mount model. Every mount is external (by-reference) now, and
    # `resolve_mount/1` (task 4.2) requires `mount_key` to be ENABLED and
    # non-degraded — disabling a by-reference mount revokes trust in that
    # outside-the-workspace location entirely, so the editor stops
    # touching it too, not just the agent/read_roots surface.
    test "page on a DISABLED mount's key is outside_workspace — disabling a by-reference mount revokes editor access too" do
      assert {:error, :outside_workspace} = ICM.page("b", "Secret.md")
    end

    test "a `..` escape cannot cross from one mount into another", %{b_root: b_root} do
      escape_path = Path.join(["..", Path.basename(b_root), "Secret.md"])
      assert {:error, :outside_workspace} = ICM.page("a", escape_path)
    end

    test "create/rename/delete operate within the resolving mount's own containment", %{
      a_root: a_root
    } do
      assert {:ok, %{path: new_page_path}} = ICM.create_page("a", "", "New")
      assert new_page_path == "New.md"

      assert {:ok, %{path: sub_path}} = ICM.create_folder("a", "", "Sub")
      assert sub_path == "Sub"

      assert {:ok, %{path: renamed_path}} = ICM.rename("a", new_page_path, "Renamed")
      assert renamed_path == "Renamed.md"

      assert {:ok, %{deleted: true}} = ICM.delete("a", renamed_path)
      refute File.exists?(Path.join(a_root, renamed_path))

      # Escaping mount a's own root while creating is denied, even though
      # mount "b" is a real, discovered mount.
      assert {:error, :outside_workspace} = ICM.create_page("a", "..", "Intruder")
    end
  end

  describe "external mounts" do
    setup %{ws: ws} do
      ext = external_icm!("Ext")
      File.mkdir_p!(Path.join(ext, "Offers"))
      File.write!(Path.join(ext, "Offers/External.md"), "# External Page\n")
      {:ok, %{mount_key: ext_key}} = Mounts.mount(ws, ext)

      %{ws: ws, mount_key: ext_key}
    end

    test "external mounts are editable via ICM ops through (mount_key, rel_path)",
         %{ws: ws, mount_key: mount_key} do
      # Sanity: the mount IS effective.
      [m] = Enum.filter(Mounts.enabled(ws), &(&1.name == mount_key))

      ext_page_rel = "Offers/External.md"
      assert File.exists?(Path.join(m.root, ext_page_rel))

      # page/2 reads the page fine, ICM-relative.
      assert {:ok, page} = ICM.page(mount_key, ext_page_rel)
      assert page.path == ext_page_rel
      assert page.content == "# External Page\n"
      assert page.uri == "icm://" <> ext_page_rel

      # create_page/3 + create_folder/3 land directly at the mount's own
      # root (parent_rel_path "").
      assert {:ok, %{path: new_page_path}} = ICM.create_page(mount_key, "", "New External")
      assert new_page_path == "New External.md"
      assert File.exists?(Path.join(m.root, new_page_path))

      assert {:ok, %{path: new_folder_path}} = ICM.create_folder(mount_key, "", "New Folder")
      assert new_folder_path == "New Folder"
      assert File.dir?(Path.join(m.root, new_folder_path))

      # rename/3 works within the mount.
      assert {:ok, %{path: renamed_path}} =
               ICM.rename(mount_key, new_page_path, "Renamed External")

      assert renamed_path == "Renamed External.md"
      refute File.exists?(Path.join(m.root, new_page_path))
      assert File.exists?(Path.join(m.root, renamed_path))

      # delete/2 of a page INSIDE the mount is a legitimate user-initiated
      # editor action (binding semantic 7).
      assert {:ok, %{deleted: true}} = ICM.delete(mount_key, renamed_path)
      refute File.exists?(Path.join(m.root, renamed_path))

      # But never the mount root itself ("" — never deletes/moves an
      # external folder wholesale).
      assert {:error, :outside_workspace} = ICM.rename(mount_key, "", "Hijacked")
      assert {:error, :outside_workspace} = ICM.delete(mount_key, "")
      assert File.dir?(m.root), "mount root must remain untouched on disk"
    end

    test "a DISABLED mount's key still gets :outside_workspace from every editor op",
         %{ws: ws, mount_key: mount_key} do
      :ok = Mounts.set_enabled(ws, mount_key, false)
      [m] = Enum.filter(Mounts.list(ws), &(&1.name == mount_key))
      ext_page_rel = "Offers/External.md"

      assert {:error, :outside_workspace} = ICM.page(mount_key, ext_page_rel)
      assert {:error, :outside_workspace} = ICM.rename(mount_key, ext_page_rel, "Renamed")
      assert {:error, :outside_workspace} = ICM.delete(mount_key, ext_page_rel)

      assert File.exists?(Path.join(m.root, ext_page_rel)),
             "disabled mount's file must be untouched"
    end
  end
end
